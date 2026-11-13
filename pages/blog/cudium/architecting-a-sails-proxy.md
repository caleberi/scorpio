---
title: 'Stop writing the same controller again and again: a declarative proxy layer in Sails JS'
summary: 'Build a config-driven proxy for a dashboard API in Sails JS: one catch-all controller, a route table, permission expressions, machine input validation and a hardened upstream client.'
authors:
  - 'Your Name'
date: '2026-11-13'
topics:
  - 'Engineering'
  - 'Sails JS'
  - 'Node.js'
  - 'Proxy'
  - 'API Design'
  - 'Dashboard'
  - 'Javascript'
  - 'Security'
type: 'Blog'
image: '![images](../../../blobs/cover60.webp)'
---

> A generic, config-driven proxy for a dashboard backend built on Sails JS. Adding an endpoint becomes a few lines of config instead of a new controller.
>
> You will learn how to match routes by hand in a catch-all controller, express permissions as data, validate inputs with `machine`, and forward requests to upstream services without opening yourself up to path traversal.
>
> PS - the code below is a trimmed, generic version. Rename the services, permissions and paths to fit your own system.

Most dashboards start the same way. There is a frontend, a Sails JS API that sits in front of it (a "backend for frontend"), and one or more internal services that hold the real data. The Sails app handles login, roles and permissions, and then forwards the request to whichever service owns the data.

At first you write a controller per endpoint. Each one looks like this:

1.  Check that the user is allowed to call it.
2.  Validate the inputs.
3.  Call the upstream service.
4.  Return whatever the upstream said (or a sensible error).

By the fortieth controller, steps 1, 3 and 4 are copy-pasted and only step 2 and the upstream path change. Bugs get fixed in one controller and not the other 39. A new teammate asks "where do we check permissions?" and the honest answer is "in every file, hopefully".

> Goal: adding a pass-through endpoint should be a config change, and the security-sensitive code should live in exactly one place.

### What is a proxy here?

In this article a proxy is **not** a reverse proxy like Nginx streaming bytes around. It is an application-level proxy:

*   It authenticates the caller (your existing auth policy).
*   It decides whether this caller may call this endpoint (permissions).
*   It validates and coerces the input before it leaves your system.
*   It builds a new request to an internal service and returns the result.

That extra context is the reason to do it in Sails rather than in a gateway: the permission model, the user record and the validation rules already live there.

### Options

You have roughly three choices:

1.  **One controller per endpoint.** Explicit and easy to read, but repetitive and easy to get subtly wrong.
2.  **A generic reverse proxy (e.g. `http-proxy-middleware`) mounted on a prefix.** Very little code, but you now forward anything under the prefix, and permissions and input validation are an afterthought.
3.  **A catch-all Sails action driven by a route table.** A little more code up front, one place for permission, validation and forwarding, and each endpoint is a declaration.

We will build option 3.

### How the pieces fit

```text
client
  |
  v
auth policy            (valid token? sets req.user)
  |
  v
explicit routes        (hand-written controllers win if they match)
  |
  v
ALL /api/v1/admin/*    -> admin/proxy action
  |
  +--> match METHOD + path against config/proxies.js
  +--> check the permission expression
  +--> validate declared inputs with machine
  +--> call the upstream service
  +--> return upstream status + body
```

The files involved:

| File | Job |
| --- | --- |
| `config/proxies.js` | The route table. One entry per proxied endpoint. |
| `config/custom.js` | Shared constants: permission names, services, methods. |
| `config/routes.js` | The catch-all route. |
| `api/controllers/admin/proxy.js` | Match, authorize, validate, forward. |
| `api/helpers/proxy-upstream.js` | Build the upstream URL safely and send the request. |
| `api/helpers/validate-proxy-routes.js` | Fail the app at lift if the table is invalid. |

### Step 1: Declare the routes

Each key is `'METHOD /path'`, relative to the prefix your dashboard API lives under (`/api/v1/admin` below). A segment that starts with `:` captures one path parameter.

```javascript
// config/proxies.js
const { permissions, access } = require('./custom').custom.constants;

module.exports.proxies = {
  'GET /orders': {
    permission: [permissions.orders, access.READ],
    inputs: {
      page: { type: 'number', isInteger: true, max: 100, defaultsTo: 1 },
      size: { type: 'number', isInteger: true, max: 25, defaultsTo: 10 },
      status: { type: 'string', isIn: ['open', 'closed', 'all'], defaultsTo: 'all' }
    },
    upstream: { service: 'core', method: 'get', path: '/admin/orders' }
  },

  'GET /orders/:orderId': {
    permission: [permissions.orders, access.READ],
    inputs: {
      orderId: { type: 'string', required: true }
    },
    upstream: { service: 'core', method: 'get', path: '/admin/orders/:orderId' }
  },

  'POST /orders/:orderId/refund': {
    permission: [permissions.refunds, access.WRITE],
    inputs: {
      orderId: { type: 'string', required: true },
      amount: { type: 'number', required: true },
      note: { type: 'string', defaultsTo: '' }
    },
    upstream: { service: 'core', method: 'post', path: '/admin/orders/:orderId/refund' }
  }
};
```

An entry has four parts:

*   **permission**: who may call it (more on the expression format in a moment).
*   **inputs**: an optional [machine](https://node-machine.org/) spec. This is the same input format Sails actions already use, so there is nothing new to learn.
*   **upstream.service**: which internal service to call.
*   **upstream.method / path**: what to call on that service. Path parameters use the same `:name` syntax.

And the constants those entries rely on:

```javascript
// config/custom.js (excerpt)
module.exports.custom = {
  constants: {
    access: { READ: 'READ', WRITE: 'WRITE' },
    permissions: {
      orders: 'orders',
      refunds: 'refunds',
      reports: 'reports'
    },
    proxy: {
      adminPrefix: '/api/v1/admin',
      services: ['core', 'reporting'],
      methods: ['get', 'post', 'put', 'patch', 'delete'],
      writeMethods: { post: true, put: true, patch: true }
    }
  },
  coreApiUrl: process.env.CORE_API_URL,
  reportingApiUrl: process.env.REPORTING_API_URL
};
```

Keeping `writeMethods` as data means the controller and the upstream client agree on which methods carry a body, instead of each hard-coding its own list.

### Step 2: One catch-all route

```javascript
// config/routes.js (last entry)
'ALL /api/v1/admin/*': { action: 'admin/proxy', skipAssets: true }
```

Two details matter here:

*   **Sails matches routes in order, so put this last.** Any hand-written controller above it wins. That gives you a painless migration path: you can move endpoints into the table one at a time and delete the old route when you do.
*   **Make sure your auth policy covers this action.** The simplest way is a default policy in `config/policies.js`, `'*': ['auth']`, and then opting specific public actions out (login, invite links). If you do not use a default, add `'admin/proxy': ['auth']` explicitly. The proxy reads `this.req.user`, so it must never run unauthenticated.

> One gotcha to remember: if a hand-written route still exists for the same method and path, the table entry will pass validation and never be reached. Delete the old route when you migrate an endpoint.

### Step 3: Match the request

Express and Sails will not match a dynamic table for you, so write the matcher. It is short, and owning it means you control the rules.

```javascript
// api/controllers/admin/proxy.js
function matchRoute(method, requestPath) {
  const { adminPrefix } = sails.config.custom.constants.proxy;
  if (requestPath.indexOf(adminPrefix) !== 0) { return null; }

  const requestSegments = requestPath.slice(adminPrefix.length).split('/').filter(Boolean);

  for (const routeKey of Object.keys(sails.config.proxies)) {
    const [routeMethod, routePath] = routeKey.split(' ');
    if (routeMethod !== method) { continue; }

    const routeSegments = routePath.split('/').filter(Boolean);
    if (routeSegments.length !== requestSegments.length) { continue; }

    const params = {};
    const matched = routeSegments.every((segment, index) => {
      if (segment.startsWith(':')) {
        params[segment.slice(1)] = requestSegments[index];
        return true;
      }
      return segment === requestSegments[index];
    });

    if (matched) {
      return { route: sails.config.proxies[routeKey], params, routeKey };
    }
  }
  return null;
}
```

Things worth knowing about this matcher:

*   **First match wins**, in the order the keys appear in the table. Put literal paths before parameterized ones with the same shape. If `GET /orders/:orderId` is listed above `GET /orders/export`, the word `export` becomes an order ID.
*   A `:param` captures exactly **one** segment, so `/orders/a/b` does not match `/orders/:orderId`.
*   No match means a `404`. The proxy never guesses.

### Step 4: Permissions as data

Hard-coding `if (user.canSeeOrders)` in a controller is exactly the thing we want to avoid. Instead, a permission is a value in the table, and one small function interprets it.

The smallest permission is a tuple: `[permissionName, 'READ' | 'WRITE']`. On top of tuples you can compose:

| Shape | Meaning |
| --- | --- |
| `[name, access]` | The caller needs that permission at that level. |
| `[expr, expr]` or `{ and: [...] }` | Every clause must pass. |
| `{ or: [...] }` | Any clause may pass. |
| `{ input, any }` | Pick the expression from a request value (a selector). |

```javascript
// api/controllers/admin/proxy.js
async function allows(user, expression, requestValues) {
  const isTuple = Array.isArray(expression) && typeof expression[0] === 'string';
  if (isTuple) {
    return sails.helpers.checkPermission.with({
      userId: user.id,
      permission: expression[0],
      action: expression[1]
    }).catch(() => false);
  }

  if (Array.isArray(expression) || expression.and) {
    const clauses = Array.isArray(expression) ? expression : expression.and;
    for (const clause of clauses) {
      if (!(await allows(user, clause, requestValues))) { return false; }
    }
    return clauses.length > 0;
  }

  if (expression.or) {
    for (const clause of expression.or) {
      if (await allows(user, clause, requestValues)) { return true; }
    }
    return false;
  }

  if (expression.input) {
    const chosen = expression.any[requestValues[expression.input]];
    return chosen ? allows(user, chosen, requestValues) : false;
  }

  return false;
}
```

Three safety decisions are baked in:

1.  **Deny by default.** An unknown shape, an empty list, or a selector value that is not in `any` all return `false`.
2.  **A failing lookup is a denial**, not a `500`. The `.catch(() => false)` turns a database error into "not allowed".
3. **A permission name in the table does not grant it to anyone.** It only describes what is required. Roles and user records still decide who has it.

Your `checkPermission` helper can be as simple or as elaborate as your role model needs. A common rule: `READ` is satisfied by a stored `READ` or `WRITE`, while `WRITE` is satisfied only by `WRITE`.

Selectors are useful when one endpoint serves different kinds of resources:

```javascript
'GET /accounts/:kind': {
  permission: {
    input: 'kind',
    any: {
      customer: [permissions.customers, access.READ],
      merchant: { or: [[permissions.merchants, access.READ], [permissions.orders, access.READ]] }
    }
  },
  inputs: { kind: { type: 'string', isIn: ['customer', 'merchant'], required: true } },
  upstream: { service: 'core', method: 'get', path: '/admin/accounts/:kind' }
}
```

> Note that the permission check runs against the **raw** request, before `defaultsTo` is applied. If a selector depends on an input, make it `required` so a missing value is a clear `400` rather than a confusing `403`.

### Step 5: Validate inputs with machine

Sails already depends on [`machine`](https://www.npmjs.com/package/machine), which is what powers the `inputs` of actions and helpers. We can reuse it to validate the route's declared inputs without writing a validator.

The idea: gather the values the route cares about, run them through a machine built from the route's spec, and use the coerced result.

```javascript
// api/controllers/admin/proxy.js
const machine = require('machine');

function inputMachine(route, routeKey) {
  if (!route.inputMachine) {
    route.inputMachine = machine.build({
      friendlyName: 'Validate ' + routeKey,
      inputs: route.inputs,
      fn: (inputs, exits) => exits.success(inputs)
    });
  }
  return route.inputMachine;
}

function pick(spec, values) {
  const picked = {};
  for (const name of Object.keys(spec)) {
    if (Object.prototype.hasOwnProperty.call(values, name)) {
      picked[name] = values[name];
    }
  }
  return picked;
}
```

Two things are easy to miss:

*   `machine.build` needs a `friendlyName` (or an `identity`). Without one it throws `E_INVALID_DEFINITION` the first time you build it.
*   The machine is built once and cached on the route, so you pay that cost on the first call to each route only.

Running it looks like this:

```javascript
let coerced = {};
if (route.inputs) {
  coerced = await inputMachine(route, routeKey)(pick(route.inputs, requestValues))
    .catch((machineError) => machineError);

  if (!coerced || coerced.code) {
    throw { badRequest: sails.helpers.errorResponse.with({ message: 'Invalid request parameters' }) };
  }
}
```

A rejected machine call comes back as an error with a `code` (`E_INVALID_ARGINS`). We catch it, return a generic `400`, and deliberately **do not** echo the machine's message to the client. It names internal input rules you do not need to publish.

What you get for free:

| Spec | Behaviour |
| --- | --- |
| `{ type: 'number' }` | `'2'` becomes `2`. `'abc'` is rejected. |
| `{ type: 'number', isInteger: true, max: 25 }` | `30` is rejected. |
| `{ type: 'string', isIn: ['open', 'closed'] }` | Anything else is rejected. |
| `{ required: true }` | A missing value is rejected. |
| `{ defaultsTo: 10 }` | A missing value becomes `10`. |

With the `GET /orders` entry above, `?page=2` is forwarded as `page=2&size=10&status=all`, and `?size=30` is a `400`.

One deliberate behaviour: **only the declared inputs are validated.** Other keys stay on the request and are forwarded as they arrived. If you want a strict allow-list instead, drop undeclared keys before forwarding. Which one is right depends on whether your upstreams ignore unknown fields.

Another: query strings are always strings. A `type: 'json'` input only makes sense on `post`, `put` and `patch`, where the value can travel in a JSON body.

### Step 6: Decide where each value goes

After validation you have a mixed bag of values and need to place them on the upstream request:

*   A value captured from the public path, or named as `:name` in the upstream path, becomes a **path parameter**.
*   On `post`, `put` and `patch`, other values go in the **body**, unless the caller already sent that name on the query string.
*   Everything else goes on the **query string**.
*   `get` and `delete` never send a body.

```javascript
function placeInputs(coerced, query, body, pathParams, upstream) {
  const { writeMethods } = sails.config.custom.constants.proxy;
  const isWrite = writeMethods[upstream.method] === true;

  for (const name of Object.keys(coerced)) {
    const isPathParam =
      Object.prototype.hasOwnProperty.call(pathParams, name) ||
      upstream.path.indexOf(':' + name) !== -1;

    if (isPathParam) {
      pathParams[name] = coerced[name];
    } else if (!isWrite || Object.prototype.hasOwnProperty.call(query, name)) {
      query[name] = coerced[name];
    } else {
      body[name] = coerced[name];
    }
  }
}
```

This is also where the table's design pays off. The public path and the upstream path do not have to look alike (`GET /orders` can call `/admin/order-list` upstream), which lets you put a stable, tidy API in front of upstreams you do not control.

### Step 7: The upstream client (where the security lives)

This is the step that deserves the most care. You are taking user-controlled strings and putting them into a URL for an internal service. Do that carelessly and a caller can walk out of the path you intended.

Consider `GET /orders/:orderId` with the request `GET /api/v1/admin/orders/..`. If you substitute that blindly into `/admin/orders/:orderId` you get `/admin/orders/..`, which many servers normalise to `/admin`. Encoded forms such as `%2e%2e` and `%2F` are the same trick wearing a disguise.

So the client:

1.  Rejects empty, `.` and `..` values, and anything containing `/`, `\` or a null byte.
2.  Checks the decoded form of the value too, and rejects a value that fails to decode.
3.  URI-encodes whatever survives.
4.  Requires every upstream path to be `/admin` or to start with `/admin/`, with no `..` anywhere.

```javascript
// api/helpers/proxy-upstream.js
function isUnsafeSegment(value) {
  const raw = String(value);
  const candidates = [raw];
  try {
    candidates.push(decodeURIComponent(raw));
  } catch (decodeError) {
    return true;
  }
  return candidates.some((candidate) =>
    candidate === '' || candidate === '.' || candidate === '..' ||
    /[/\\\0]/.test(candidate));
}

function buildUrl(pathTemplate, params, query) {
  const segments = pathTemplate.split('/').map((segment) => {
    if (!segment.startsWith(':')) { return segment; }
    const value = params[segment.slice(1)];
    if (value === undefined || value === null || isUnsafeSegment(value)) { return null; }
    return encodeURIComponent(String(value));
  });
  if (segments.includes(null)) { return null; }

  const pairs = Object.entries(query || {})
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => encodeURIComponent(key) + '=' + encodeURIComponent(String(value)));

  return segments.join('/') + (pairs.length ? '?' + pairs.join('&') : '');
}
```

Used like this, `orderId = 'a b'` becomes `/admin/orders/a%20b`, while `..`, `%2e%2e`, `%2F` and a lone `%` all return `null`.

The helper wrapper picks the right pre-configured client for the service and sends the request:

```javascript
// api/helpers/proxy-upstream.js (continued)
const axios = require('axios');

function clientFor(service) {
  const { coreApiUrl, reportingApiUrl } = sails.config.custom;
  const baseURL = service === 'reporting' ? reportingApiUrl : coreApiUrl;
  return axios.create({
    baseURL,
    timeout: 10000,
    headers: { 'Content-Type': 'application/json' },
    validateStatus: () => true
  });
}

module.exports = {
  friendlyName: 'Proxy upstream',
  description: 'Send a request to an explicit upstream path.',

  inputs: {
    service: { type: 'string', required: true },
    method: { type: 'string', required: true },
    path: { type: 'string', required: true },
    params: { type: 'ref', defaultsTo: {} },
    query: { type: 'ref' },
    body: { type: 'ref' }
  },

  fn: async function ({ service, method, path, params, query, body }) {
    const url = buildUrl(path, params, query);
    if (!url) { return null; }

    const { writeMethods } = sails.config.custom.constants.proxy;
    const sendsBody = writeMethods[method] === true && body !== undefined;

    return clientFor(service).request({
      method,
      url,
      data: sendsBody ? body : undefined
    }).catch((error) => error.response || null);
  }
};
```

Notes on the choices above:

*   `validateStatus: () => true` makes axios resolve for every HTTP status. An upstream `422` should reach the dashboard as a `422`, not turn into an exception.
*   A timeout is not optional. Without one, a hung upstream ties up a Sails request for as long as the client keeps waiting.
*   If you sign requests to your upstreams (an HMAC header, a service token), do it **here**, in the one place that builds the client. No route in the table should ever need to think about it.
*   `null` means "I could not build or send this request". The controller turns that into a `502`.

### Step 8: Put it together in the action

```javascript
// api/controllers/admin/proxy.js
module.exports = {
  friendlyName: 'Admin proxy',
  description: 'Check the route permission, validate declared inputs, and forward the request upstream.',

  inputs: {},

  exits: {
    badRequest: { statusCode: 400 },
    forbidden: { statusCode: 403 },
    notFound: { statusCode: 404 },
    badGateway: { statusCode: 502 }
  },

  fn: async function () {
    const found = matchRoute(this.req.method, this.req.path);
    if (!found) {
      throw { notFound: sails.helpers.errorResponse.with({ message: 'Route is not registered' }) };
    }

    const { route, params, routeKey } = found;
    const requestValues = Object.assign({}, this.req.query, this.req.body, params);

    if (!(await allows(this.req.user, route.permission, requestValues))) {
      throw { forbidden: sails.helpers.errorResponse.with({ message: 'You do not have permission to access this route' }) };
    }

    let coerced = {};
    if (route.inputs) {
      coerced = await inputMachine(route, routeKey)(pick(route.inputs, requestValues))
        .catch((machineError) => machineError);
      if (!coerced || coerced.code) {
        throw { badRequest: sails.helpers.errorResponse.with({ message: 'Invalid request parameters' }) };
      }
    }

    const query = Object.assign({}, this.req.query);
    const body = Object.assign({}, this.req.body);
    const pathParams = Object.assign({}, params);
    placeInputs(coerced, query, body, pathParams, route.upstream);

    const upstreamResponse = await sails.helpers.proxyUpstream.with({
      service: route.upstream.service,
      method: route.upstream.method,
      path: route.upstream.path,
      params: pathParams,
      query,
      body
    });

    if (!upstreamResponse || typeof upstreamResponse.status !== 'number') {
      throw { badGateway: sails.helpers.errorResponse.with({ message: 'Upstream request failed' }) };
    }

    sendUpstream(this.res, upstreamResponse);
  }
};
```

`sendUpstream` writes the upstream status and body to the response:

```javascript
function sendUpstream(res, upstreamResponse) {
  const data = upstreamResponse.data;
  const payload = typeof data === 'string' ? data : JSON.stringify(data === undefined ? null : data);

  res.writeHead(upstreamResponse.status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.write(payload);
}
```

It uses `res.writeHead` and `res.write` rather than `res.json`, and it never calls `res.end()`. In a Sails action, `res.json()` ends the response, and when the action then returns, Sails tries to send its own success response and fails with a "headers already sent" error. Writing without ending lets Sails finish the response when the action resolves.

The ordering is deliberate. **Authorize first, validate second.** A caller without permission should learn nothing about your input rules, and you should not spend cycles validating a request you are about to refuse.

The status codes line up like this:

| Status | When |
| --- | --- |
| `400` | A declared input fails its machine spec |
| `403` | The permission expression does not pass |
| `404` | No table entry matches the method and path |
| `502` | The upstream request failed with no HTTP response |
| anything else | The upstream's own status, passed through untouched |

### Step 9: Fail at lift, not at 2 a.m.

The table is configuration, and configuration gets typos. If someone writes `'READ '` with a trailing space or points a route at `/v1/orders` instead of `/admin/orders`, you want to find out when the app boots, not when a user clicks a button.

Build the same checks out of machines and run them for every entry in `bootstrap`:

```javascript
// api/helpers/validate-proxy-routes.js
const machine = require('machine');

module.exports = {
  friendlyName: 'Validate proxy routes',
  description: 'Fail lift when a proxy route has a bad permission expression or upstream target.',

  fn: async function () {
    const { permissions, access, proxy } = sails.config.custom.constants;

    const leaf = machine.build({
      friendlyName: 'Validate permission tuple',
      inputs: {
        permission: { type: 'string', required: true, isIn: Object.values(permissions) },
        access: { type: 'string', required: true, isIn: Object.values(access) }
      },
      fn: (values, exits) => exits.success(values)
    });

    const target = machine.build({
      friendlyName: 'Validate upstream target',
      inputs: {
        service: { type: 'string', required: true, isIn: proxy.services },
        method: { type: 'string', required: true, isIn: proxy.methods },
        path: {
          type: 'string',
          required: true,
          custom: (path) => (path === '/admin' || path.startsWith('/admin/')) && !path.includes('..')
        }
      },
      fn: (values, exits) => exits.success(values)
    });

    for (const routeKey of Object.keys(sails.config.proxies)) {
      const route = sails.config.proxies[routeKey];
      await assertExpression(route.permission, leaf, routeKey);
      await assertTarget(route.upstream, target, routeKey);
    }
  }
};
```

`assertExpression` walks the permission tree and runs each tuple through `leaf`. `assertTarget` runs the upstream through `target`. Both throw an `Error` that names the route key when something is off.

Then call it from `config/bootstrap.js`:

```javascript
module.exports.bootstrap = async function () {
  await sails.helpers.validateProxyRoutes();
  // ...the rest of your bootstrap
};
```

Because a throw in `bootstrap` stops `sails lift`, a bad table can never reach production. These are the kinds of mistakes it catches:

| Mistake | Why it fails |
| --- | --- |
| Permission name not in `constants.permissions` | Typos are caught before any user hits a `403` |
| Access of `'read'` | Access must be `READ` or `WRITE` |
| `{ or: [] }` | A permission with no clauses can never pass |
| `method: 'GET'` | The upstream method is lowercase |
| `service: 'ledger'` | Not a declared service |
| `path: '/v1/orders'` | Upstream paths must live under `/admin` |
| `path: '/admin/../secret'` | No traversal in the path template |

### Adding an endpoint now

1.  If it needs a new permission, add it to `constants.permissions`, and assign it to the roles that should have it.
2.  Add one entry to `config/proxies.js`.
3.  Check `config/routes.js` for an older hand-written route on the same path and remove it.
4.  Lift the app. If the entry is invalid, the error names the route key.
5.  Call it as a user who holds the permission, and as one who does not.

For example, a read-only reporting endpoint that forwards to another service:

```javascript
'GET /reports/summary': {
  permission: [permissions.reports, access.READ],
  upstream: { service: 'reporting', method: 'get', path: '/admin/reports/summary' }
}
```

That is the whole change. No controller, no route line, no new permission code.

You can also choose the upstream service from the request, which is handy when two systems expose the same endpoint for different kinds of resource. Use a selector in `upstream.service` and give the input `required` and `isIn` so an unknown value is a `400` rather than falling through to a default:

```javascript
upstream: {
  service: { input: 'kind', any: { customer: 'core', merchant: 'reporting' } },
  method: 'get',
  path: '/admin/summary'
}
```

### Gotchas worth remembering

1.  **Route order matters twice.** Sails matches `routes.js` top to bottom, and the matcher walks the proxy table top to bottom. Literal before parameterized, specific before catch-all.
2.  **Defaults apply after the permission check.** Permission selectors see the raw request; service selectors and the upstream call see defaulted values.
3.  **`get` and `delete` drop the body.** If an upstream needs a field, send it as a query parameter.
4.  **Undeclared fields are forwarded.** Decide on purpose whether that is what you want.
5.  **A path parameter the upstream path never mentions is not forwarded.** It is still available to permissions and service selectors, so it can drive a decision without becoming part of the URL.
6.  **The proxy rewrites errors only when the upstream fails to answer.** If the upstream returns a `500` with an internal stack trace in the body, you will pass it through. Decide whether to sanitise upstream error bodies before they reach the browser.

### Testing it

The two pieces most worth unit testing are pure functions: the matcher and the URL builder. A few assertions cover most of the risk:

```javascript
const assert = require('assert');

assert.strictEqual(matchRoute('GET', '/api/v1/admin/orders/export').routeKey, 'GET /orders/export');
assert.strictEqual(matchRoute('GET', '/api/v1/admin/orders/abc').routeKey, 'GET /orders/:orderId');
assert.strictEqual(matchRoute('GET', '/api/v1/admin/orders/a/b'), null);
assert.strictEqual(matchRoute('DELETE', '/api/v1/admin/orders/abc'), null);

assert.strictEqual(buildUrl('/admin/orders/:orderId', { orderId: 'a b' }, { x: 1 }), '/admin/orders/a%20b?x=1');
assert.strictEqual(buildUrl('/admin/orders/:orderId', { orderId: '..' }), null);
assert.strictEqual(buildUrl('/admin/orders/:orderId', { orderId: '%2e%2e' }), null);
assert.strictEqual(buildUrl('/admin/orders/:orderId', { orderId: '%2F' }), null);
```

Then try the whole thing with `curl`:

```bash
# allowed
curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:1337/api/v1/admin/orders?page=1&size=10&status=open"

# 400: size above max
curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:1337/api/v1/admin/orders?size=30"

# 404: not in the table
curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:1337/api/v1/admin/not-a-route"
```

### What we gained

1.  One place for authorization, validation, path safety and error mapping.
2.  New pass-through endpoints are a few lines of config and a quick review.
3.  A dashboard API shape that is independent of the upstream's shape.
4.  Mistakes in the table fail at lift instead of in production.
5.  Reviewers can read a diff of `proxies.js` and see exactly who can call what.
6.  A migration path: hand-written controllers and table entries coexist while you move over.

### Trade-offs

1.  **It is a mini framework you now own.** The matcher, permission walker and client need tests and an owner.
2.  **Anything with real logic still wants a controller.** Aggregating two upstream calls, reshaping a response or enforcing a business rule does not belong in a declarative table. Keep those as ordinary Sails actions above the catch-all.
3.  **One more hop.** Every call adds a network round trip. Keep timeouts tight and cache where it is safe.
4.  **The catch-all is a broad door.** Everything under the prefix lands in one action, so the deny-by-default behaviour and lift-time validation above are not optional extras.

Whether this beats a controller per endpoint depends on how much of your controller code is boilerplate. If most of it is, a table is a better trade. If most endpoints carry real logic, you will not save much.

I hope you picked up a few ideas for how to put a thin, safe and declarative layer between a dashboard and the services behind it, and a nicer way of using the `machine` inputs Sails already ships with.

Resources:  
\- [Sails custom routes](https://sailsjs.com/documentation/concepts/routes/custom-routes)  
\- [Sails policies](https://sailsjs.com/documentation/concepts/policies)  
\- [Sails actions and controllers](https://sailsjs.com/documentation/concepts/actions-and-controllers)  
\- [Sails helpers](https://sailsjs.com/documentation/concepts/helpers)  
\- [Sails bootstrap](https://sailsjs.com/documentation/reference/configuration/sails-config-bootstrap)  
\- [Node-Machine spec](https://node-machine.org/spec/machine)  
\- [OWASP path traversal](https://owasp.org/www-community/attacks/Path_Traversal)

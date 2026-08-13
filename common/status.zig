const std = @import("std");
const http = std.http;

/// HTTP status codes as a Zig error set (for propagating non-success responses).
pub const StatusError = error{
    // 1xx
    Continue,
    SwitchingProtocols,
    Processing,
    EarlyHints,

    // 2xx
    Ok,
    Created,
    Accepted,
    NonAuthoritativeInfo,
    NoContent,
    ResetContent,
    PartialContent,
    MultiStatus,
    AlreadyReported,
    ImUsed,

    // 3xx
    MultipleChoice,
    MovedPermanently,
    Found,
    SeeOther,
    NotModified,
    UseProxy,
    TemporaryRedirect,
    PermanentRedirect,

    // 4xx
    BadRequest,
    Unauthorized,
    PaymentRequired,
    Forbidden,
    NotFound,
    MethodNotAllowed,
    NotAcceptable,
    ProxyAuthRequired,
    RequestTimeout,
    Conflict,
    Gone,
    LengthRequired,
    PreconditionFailed,
    PayloadTooLarge,
    UriTooLong,
    UnsupportedMediaType,
    RangeNotSatisfiable,
    ExpectationFailed,
    Teapot,
    MisdirectedRequest,
    UnprocessableEntity,
    Locked,
    FailedDependency,
    TooEarly,
    UpgradeRequired,
    PreconditionRequired,
    TooManyRequests,
    RequestHeaderFieldsTooLarge,
    UnavailableForLegalReasons,

    // 5xx
    InternalServerError,
    NotImplemented,
    BadGateway,
    ServiceUnavailable,
    GatewayTimeout,
    HttpVersionNotSupported,
    VariantAlsoNegotiates,
    InsufficientStorage,
    LoopDetected,
    NotExtended,
    NetworkAuthenticationRequired,

    UnknownError,
};

pub fn getStatusError(status: http.Status) StatusError {
    return switch (status) {
        // 1xx
        .@"continue" => error.Continue,
        .switching_protocols => error.SwitchingProtocols,
        .processing => error.Processing,
        .early_hints => error.EarlyHints,

        // 2xx
        .ok => error.Ok,
        .created => error.Created,
        .accepted => error.Accepted,
        .non_authoritative_info => error.NonAuthoritativeInfo,
        .no_content => error.NoContent,
        .reset_content => error.ResetContent,
        .partial_content => error.PartialContent,
        .multi_status => error.MultiStatus,
        .already_reported => error.AlreadyReported,
        .im_used => error.ImUsed,

        // 3xx
        .multiple_choice => error.MultipleChoice,
        .moved_permanently => error.MovedPermanently,
        .found => error.Found,
        .see_other => error.SeeOther,
        .not_modified => error.NotModified,
        .use_proxy => error.UseProxy,
        .temporary_redirect => error.TemporaryRedirect,
        .permanent_redirect => error.PermanentRedirect,

        // 4xx
        .bad_request => error.BadRequest,
        .unauthorized => error.Unauthorized,
        .payment_required => error.PaymentRequired,
        .forbidden => error.Forbidden,
        .not_found => error.NotFound,
        .method_not_allowed => error.MethodNotAllowed,
        .not_acceptable => error.NotAcceptable,
        .proxy_auth_required => error.ProxyAuthRequired,
        .request_timeout => error.RequestTimeout,
        .conflict => error.Conflict,
        .gone => error.Gone,
        .length_required => error.LengthRequired,
        .precondition_failed => error.PreconditionFailed,
        .payload_too_large => error.PayloadTooLarge,
        .uri_too_long => error.UriTooLong,
        .unsupported_media_type => error.UnsupportedMediaType,
        .range_not_satisfiable => error.RangeNotSatisfiable,
        .expectation_failed => error.ExpectationFailed,
        .teapot => error.Teapot,
        .misdirected_request => error.MisdirectedRequest,
        .unprocessable_entity => error.UnprocessableEntity,
        .locked => error.Locked,
        .failed_dependency => error.FailedDependency,
        .too_early => error.TooEarly,
        .upgrade_required => error.UpgradeRequired,
        .precondition_required => error.PreconditionRequired,
        .too_many_requests => error.TooManyRequests,
        .request_header_fields_too_large => error.RequestHeaderFieldsTooLarge,
        .unavailable_for_legal_reasons => error.UnavailableForLegalReasons,

        // 5xx
        .internal_server_error => error.InternalServerError,
        .not_implemented => error.NotImplemented,
        .bad_gateway => error.BadGateway,
        .service_unavailable => error.ServiceUnavailable,
        .gateway_timeout => error.GatewayTimeout,
        .http_version_not_supported => error.HttpVersionNotSupported,
        .variant_also_negotiates => error.VariantAlsoNegotiates,
        .insufficient_storage => error.InsufficientStorage,
        .loop_detected => error.LoopDetected,
        .not_extended => error.NotExtended,
        .network_authentication_required => error.NetworkAuthenticationRequired,

        else => error.UnknownError,
    };
}

const testing = std.testing;

test "getStatusError" {
    const Case = struct {
        status: http.Status,
        expected: StatusError,
    };

    const cases = [_]Case{
        .{ .status = .@"continue", .expected = error.Continue },
        .{ .status = .ok, .expected = error.Ok },
        .{ .status = .created, .expected = error.Created },
        .{ .status = .not_modified, .expected = error.NotModified },
        .{ .status = .bad_request, .expected = error.BadRequest },
        .{ .status = .unauthorized, .expected = error.Unauthorized },
        .{ .status = .forbidden, .expected = error.Forbidden },
        .{ .status = .not_found, .expected = error.NotFound },
        .{ .status = .request_timeout, .expected = error.RequestTimeout },
        .{ .status = .payload_too_large, .expected = error.PayloadTooLarge },
        .{ .status = .teapot, .expected = error.Teapot },
        .{ .status = .too_many_requests, .expected = error.TooManyRequests },
        .{ .status = .internal_server_error, .expected = error.InternalServerError },
        .{ .status = .service_unavailable, .expected = error.ServiceUnavailable },
        .{ .status = .network_authentication_required, .expected = error.NetworkAuthenticationRequired },
        .{ .status = @enumFromInt(599), .expected = error.UnknownError },
    };

    for (cases) |case| {
        try testing.expectEqual(case.expected, getStatusError(case.status));
    }
}

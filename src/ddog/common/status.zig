const std = @import("std");
const http = std.http;
pub const StatusError = error{
    BadRequest,
    UnAuthorized,
    Forbidden,
    NotFound,
    PayloadTooLarge,
    Timeout,
    ToManyRequest,
    InternalServerError,
    ServiceUnavailable,
    UnknownError,
};

pub fn getStatusError(status: http.Status) StatusError {
    return switch (status) {
        .bad_request => error.BadRequest,
        .unauthorized => error.UnAuthorized,
        .forbidden => error.Forbidden,
        .not_found => error.NotFound,
        .request_timeout => error.Timeout,
        .payload_too_large => error.PayloadTooLarge,
        .too_many_requests => error.ToManyRequest,
        .internal_server_error => error.InternalServerError,
        .service_unavailable => error.ServiceUnavailable,
        else => error.UnknownError,
    };
}

const zstd = @import("std");
const engine = @import("engine.zig");

const Context = engine.Context;
const ValidationError = engine.ValidationError;
const ValidationResult = engine.ValidationResult;
const ValidationReturnType = engine.ValidationReturnType;

pub fn alphaValidator(ctx: Context) ValidationReturnType {
    const s = ctx.value.asString() orelse {
        return ValidationResult.failure("Field must be a string for alpha validation");
    };
    for (s) |c| {
        if (!zstd.ascii.isAlphabetic(c) and c != ' ') {
            return ValidationResult.failure("Field must contain only alphabetic characters");
        }
    }
    return ValidationResult.success();
}

pub fn numericValidator(ctx: Context) ValidationReturnType {
    if (ctx.value.asInt() == null) {
        return ValidationResult.failure("Field must be numeric");
    }
    return ValidationResult.success();
}

fn requireIntParam(ctx: Context) ValidationError!i64 {
    if (ctx.params.len == 0) return ValidationError.InvalidParameterCount;
    return ctx.params[0].asInt() orelse ValidationError.InvalidParameterType;
}

fn requireUsizeParam(ctx: Context) ValidationError!usize {
    const n = try requireIntParam(ctx);
    if (n < 0) return ValidationError.InvalidParameterType;
    return @intCast(n);
}

pub fn minLengthValidator(ctx: Context) ValidationReturnType {
    const min_len = try requireUsizeParam(ctx);

    const s = ctx.value.asString() orelse {
        return ValidationResult.failure("Field must be a string for length validation");
    };

    if (s.len < min_len) {
        return ValidationResult.failure("Field length is below minimum");
    }
    return ValidationResult.success();
}

pub fn maxLengthValidator(ctx: Context) ValidationReturnType {
    const max_len = try requireUsizeParam(ctx);

    const s = ctx.value.asString() orelse {
        return ValidationResult.failure("Field must be a string for length validation");
    };

    if (s.len > max_len) {
        return ValidationResult.failure("Field length exceeds maximum");
    }
    return ValidationResult.success();
}

pub fn minValidator(ctx: Context) ValidationReturnType {
    const min_val = try requireIntParam(ctx);

    const value = ctx.value.asInt() orelse {
        return ValidationResult.failure("Field must be numeric for min validation");
    };

    if (value < min_val) {
        return ValidationResult.failure("Value is below minimum");
    }
    return ValidationResult.success();
}

pub fn maxValidator(ctx: Context) ValidationReturnType {
    const max_val = try requireIntParam(ctx);

    const value = ctx.value.asInt() orelse {
        return ValidationResult.failure("Field must be numeric for max validation");
    };

    if (value > max_val) {
        return ValidationResult.failure("Value exceeds maximum");
    }
    return ValidationResult.success();
}

pub fn requiredValidator(ctx: Context) ValidationReturnType {
    switch (ctx.value) {
        .string => |s| {
            if (s.len == 0) {
                return ValidationResult.failure("Field is required");
            }
        },
        .other => return ValidationResult.failure("Field is required"),
        .int, .float, .boolean => {},
    }
    return ValidationResult.success();
}

pub fn emailValidator(ctx: Context) ValidationReturnType {
    const s = ctx.value.asString() orelse {
        return ValidationResult.failure("Field must be a string for email validation");
    };
    const has_at = zstd.mem.indexOf(u8, s, "@") != null;
    const has_dot = zstd.mem.indexOf(u8, s, ".") != null;

    if (!has_at or !has_dot) {
        return ValidationResult.failure("Invalid email format");
    }
    return ValidationResult.success();
}

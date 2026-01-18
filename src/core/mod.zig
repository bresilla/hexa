// Core - built entirely on ghostty-vt

pub const pty = @import("pty.zig");
pub const vt = @import("vt.zig");
pub const config = @import("config.zig");

pub const Pty = pty.Pty;
pub const VT = vt.VT;
pub const Config = config.Config;
pub const FloatDef = config.FloatDef;
pub const FloatStyle = config.FloatStyle;
pub const FloatStylePosition = config.FloatStylePosition;
pub const BorderColor = config.BorderColor;
pub const SplitStyle = config.SplitStyle;
pub const SplitsConfig = config.SplitsConfig;
pub const PanesConfig = config.PanesConfig;
pub const StatusModule = config.StatusModule;
pub const OutputDef = config.OutputDef;

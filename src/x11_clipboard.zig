const std = @import("std");
const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
});

pub const X11Clipboard = struct {
    allocator: std.mem.Allocator,
    display: ?*x11.Display,
    window: x11.Window,
    atoms: struct {
        clipboard: x11.Atom,
        targets: x11.Atom,
        string: x11.Atom,
        utf8_string: x11.Atom,
        property: x11.Atom,
    },

    pub fn init(allocator: std.mem.Allocator) !X11Clipboard {
        const display = x11.XOpenDisplay(null) orelse return error.ConnectionFailed;
        const window = x11.XCreateSimpleWindow(display, x11.XDefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0);

        const atoms = .{
            .clipboard = x11.XInternAtom(display, "CLIPBOARD", 0),
            .targets = x11.XInternAtom(display, "TARGETS", 0),
            .string = x11.XA_STRING,
            .utf8_string = x11.XInternAtom(display, "UTF8_STRING", 0),
            .property = x11.XInternAtom(display, "CLIP_PROPERTY", 0),
        };

        return X11Clipboard{
            .allocator = allocator,
            .display = display,
            .window = window,
            .atoms = atoms,
        };
    }

    pub fn getText(self: *X11Clipboard) ![]const u8 {
        if (self.display == null) return error.NoDisplay;

        _ = x11.XConvertSelection(
            self.display,
            self.atoms.clipboard,
            self.atoms.utf8_string,
            self.atoms.property,
            self.window,
            x11.CurrentTime,
        );
        _ = x11.XFlush(self.display);

        var event: x11.XEvent = undefined;
        var success = false;
        var timeout: usize = 0;
        const max_attempts = 10;

        while (!success and timeout < max_attempts) : (timeout += 1) {
            _ = x11.XNextEvent(self.display, &event);

            if (event.type == x11.SelectionNotify) {
                const selection_event = @as(*x11.XSelectionEvent, @ptrCast(&event));

                if (selection_event.property != x11.None) {
                    var actual_type: x11.Atom = undefined;
                    var actual_format: c_int = undefined;
                    var nitems: c_ulong = undefined;
                    var bytes_after: c_ulong = undefined;
                    var data: [*c]u8 = undefined;

                    const status = x11.XGetWindowProperty(
                        self.display,
                        self.window,
                        self.atoms.property,
                        0,
                        std.math.maxInt(c_long),
                        1, // Delete the property
                        x11.AnyPropertyType,
                        &actual_type,
                        &actual_format,
                        &nitems,
                        &bytes_after,
                        &data,
                    );

                    if (status == x11.Success and data != null) {
                        const content = try self.allocator.dupe(u8, data[0..nitems]);
                        _ = x11.XFree(data);
                        return content;
                    }
                }
                success = true;
            }
            std.time.sleep(10 * std.time.ns_per_ms);
        }

        return error.NoClipboardContent;
    }

    pub fn setText(self: *X11Clipboard, text: []const u8) !void {
        if (self.display == null) return error.NoDisplay;

        _ = x11.XSetSelectionOwner(
            self.display,
            self.atoms.clipboard,
            self.window,
            x11.CurrentTime,
        );

        if (x11.XGetSelectionOwner(self.display, self.atoms.clipboard) != self.window) {
            return error.FailedToSetOwner;
        }

        // Store the text for when other applications request it
        const text_copy = try self.allocator.dupe(u8, text);
        _ = x11.XChangeProperty(
            self.display,
            self.window,
            self.atoms.property,
            self.atoms.utf8_string,
            8,
            x11.PropModeReplace,
            text_copy.ptr,
            @intCast(text_copy.len),
        );
        _ = x11.XFlush(self.display);
    }

    pub fn deinit(self: *X11Clipboard) void {
        if (self.display) |display| {
            _ = x11.XDestroyWindow(display, self.window);
            _ = x11.XCloseDisplay(display);
            self.display = null;
        }
    }
};

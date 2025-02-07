const std = @import("std");
const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
});

pub const ClipboardEntry = struct {
    content: []const u8,
    timestamp: i64,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) !ClipboardEntry {
        const content_copy = try allocator.dupe(u8, content);
        return ClipboardEntry{
            .content = content_copy,
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *ClipboardEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const ClipboardManager = struct {
    allocator: std.mem.Allocator,
    display: ?*x11.Display,
    window: x11.Window,
    entries: std.ArrayList(ClipboardEntry),
    max_entries: usize,
    current_selection: []const u8,
    mutex: std.Thread.Mutex,
    last_clipboard_content: []const u8,
    on_update: ?*const fn (self: *ClipboardManager) void,

    pub fn init(allocator: std.mem.Allocator, max_entries: usize, on_update: ?*const fn (self: *ClipboardManager) void) !*ClipboardManager {
        const self = try allocator.create(ClipboardManager);
        self.* = .{
            .allocator = allocator,
            .display = null,
            .window = 0,
            .entries = std.ArrayList(ClipboardEntry).init(allocator),
            .max_entries = max_entries,
            .current_selection = &[_]u8{},
            .mutex = .{},
            .last_clipboard_content = &[_]u8{},
            .on_update = on_update,
        };
        return self;
    }

    pub fn connect(self: *ClipboardManager) !void {
        self.display = x11.XOpenDisplay(null) orelse return error.ConnectionFailed;
        self.window = x11.XCreateSimpleWindow(self.display, x11.XDefaultRootWindow(self.display), 0, 0, 1, 1, 0, 0, 0);
        if (self.window == 0) return error.WindowCreationFailed;

        const clipboard_atom = x11.XInternAtom(self.display, "CLIPBOARD", 0);
        _ = x11.XSetSelectionOwner(self.display, clipboard_atom, self.window, x11.CurrentTime);
    }

    pub fn addEntry(self: *ClipboardManager, content: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Skip duplicate entries
        if (self.entries.items.len > 0 and
            std.mem.eql(u8, self.entries.items[self.entries.items.len - 1].content, content))
        {
            std.debug.print("Skipping duplicate entry: {s}\n", .{content});
            return;
        }

        const entry = try ClipboardEntry.init(self.allocator, content);
        try self.entries.append(entry);

        if (self.entries.items.len > self.max_entries) {
            var removed = self.entries.orderedRemove(0);
            removed.deinit(self.allocator);
        }

        std.debug.print("Added new entry: {s}\n", .{content});

        // Trigger update callback
        if (self.on_update) |callback| {
            callback(self);
        }
    }

    pub fn getEntries(self: *ClipboardManager) []const ClipboardEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items;
    }

    pub fn listenForClipboardChanges(self: *ClipboardManager) !void {
        if (self.display) |display| {
            const clipboard = x11.XInternAtom(display, "CLIPBOARD", 0);
            const target = x11.XA_STRING;
            const property = x11.XInternAtom(display, "CLIPBOARD_CONTENT", 0);

            std.debug.print("Clipboard listener started\n", .{});

            while (true) {
                var event: x11.XEvent = undefined;
                _ = x11.XNextEvent(display, &event);

                if (event.type == x11.SelectionRequest) {
                    std.debug.print("SelectionRequest event received\n", .{});
                    self.handleSelectionRequest(&event);
                } else if (event.type == x11.SelectionClear) {
                    std.debug.print("SelectionClear event received (lost clipboard ownership)\n", .{});
                    self.handleSelectionClear();
                }

                // Periodically check clipboard content
                std.time.sleep(500 * std.time.ns_per_ms);
                const current_content = self.getCurrentClipboardContent(display, clipboard, target, property);

                if (current_content) |content| {
                    defer self.allocator.free(content);
                    std.debug.print("Clipboard content retrieved: {s}\n", .{content});
                    try self.addEntry(content);
                } else |err| {
                    std.debug.print("Failed to retrieve clipboard content: {}\n", .{err});
                }
            }
        } else {
            return error.NoDisplayConnection;
        }
    }

    fn getCurrentClipboardContent(self: *ClipboardManager, display: *x11.Display, clipboard: x11.Atom, target: x11.Atom, property: x11.Atom) ![]const u8 {
        _ = x11.XConvertSelection(display, clipboard, target, property, self.window, x11.CurrentTime);
        _ = x11.XFlush(display);

        var event: x11.XEvent = undefined;
        _ = x11.XNextEvent(display, &event);

        if (event.type == x11.SelectionNotify) {
            const selection_event = @as(*x11.XSelectionEvent, @ptrCast(&event));
            if (selection_event.property != x11.None) {
                var actual_type: x11.Atom = undefined;
                var actual_format: c_int = undefined;
                var nitems: c_ulong = undefined;
                var bytes_after: c_ulong = undefined;
                var data: [*c]u8 = undefined;

                const status = x11.XGetWindowProperty(
                    display,
                    self.window,
                    selection_event.property,
                    0,
                    std.math.maxInt(c_long),
                    0,
                    target,
                    &actual_type,
                    &actual_format,
                    &nitems,
                    &bytes_after,
                    &data,
                );

                if (status == x11.Success and data != null) {
                    const content = try self.allocator.dupe(u8, std.mem.span(data));
                    _ = x11.XFree(data);
                    return content;
                } else {
                    std.debug.print("XGetWindowProperty failed or returned null data\n", .{});
                }
            } else {
                std.debug.print("SelectionNotify event has no property\n", .{});
            }
        } else {
            std.debug.print("Unexpected event type: {}\n", .{event.type});
        }

        return error.NoClipboardContent;
    }

    fn handleSelectionRequest(self: *ClipboardManager, event: *x11.XEvent) void {
        const selection_request = @as(*x11.XSelectionRequestEvent, @ptrCast(event));
        var response: x11.XEvent = undefined;
        response.xselection.type = x11.SelectionNotify;
        response.xselection.requestor = selection_request.requestor;
        response.xselection.selection = selection_request.selection;
        response.xselection.target = selection_request.target;
        response.xselection.time = selection_request.time;

        if (self.entries.items.len > 0) {
            const last_entry = self.entries.items[self.entries.items.len - 1];
            std.debug.print("Handling selection request with content: {s}\n", .{last_entry.content});
            _ = x11.XChangeProperty(self.display.?, selection_request.requestor, selection_request.property, selection_request.target, 8, x11.PropModeReplace, @as([*c]const u8, @ptrCast(last_entry.content.ptr)), @intCast(last_entry.content.len));
            response.xselection.property = selection_request.property;
        } else {
            response.xselection.property = x11.None;
        }

        _ = x11.XSendEvent(self.display.?, selection_request.requestor, 0, 0, &response);
        _ = x11.XFlush(self.display.?);
    }

    fn handleSelectionClear(self: *ClipboardManager) void {
        _ = self; // Acknowledge the unused parameter
        std.debug.print("Lost clipboard ownership\n", .{});
    }

    pub fn deinit(self: *ClipboardManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();

        if (self.display) |display| {
            _ = x11.XDestroyWindow(display, self.window);
            _ = x11.XCloseDisplay(display);
        }

        self.allocator.destroy(self);
    }
};

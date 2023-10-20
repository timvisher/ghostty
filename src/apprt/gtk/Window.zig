/// A Window is a single, real GTK window.
const Window = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../../build_config.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const configpkg = @import("../../config.zig");
const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const App = @import("App.zig");
const Paned = @import("Paned.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const icon = @import("icon.zig");
const c = @import("c.zig");

const log = std.log.scoped(.gtk);

app: *App,

/// Our window
window: *c.GtkWindow,

/// The notebook (tab grouping) for this window.
notebook: *c.GtkNotebook,

/// The resources directory for the icon (if any). We need to retain a
/// pointer to this because GTK can use it at any time.
icon: icon.Icon,

tabs: std.ArrayListUnmanaged(*Tab),

pub fn create(alloc: Allocator, app: *App) !*Window {
    // Allocate a fixed pointer for our window. We try to minimize
    // allocations but windows and other GUI requirements are so minimal
    // compared to the steady-state terminal operation so we use heap
    // allocation for this.
    //
    // The allocation is owned by the GtkWindow created. It will be
    // freed when the window is closed.
    var window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(app);
    return window;
}

pub fn init(self: *Window, app: *App) !void {
    // Set up our own state
    self.* = .{
        .app = app,
        .icon = undefined,
        .window = undefined,
        .notebook = undefined,
        .tabs = undefined,
    };

    var tabs: std.ArrayListUnmanaged(*Tab) = .{};
    errdefer tabs.deinit(app.core_app.alloc);
    self.tabs = tabs;

    // Create the window
    const window = c.gtk_application_window_new(app.app);
    const gtk_window: *c.GtkWindow = @ptrCast(window);
    errdefer c.gtk_window_destroy(gtk_window);
    self.window = gtk_window;
    c.gtk_window_set_title(gtk_window, "Ghostty");
    c.gtk_window_set_default_size(gtk_window, 1000, 600);

    // GTK4 grabs F10 input by default to focus the menubar icon. We want
    // to disable this so that terminal programs can capture F10 (such as htop)
    c.gtk_window_set_handle_menubar_accel(gtk_window, 0);

    // If we don't have the icon then we'll try to add our resources dir
    // to the search path and see if we can find it there.
    self.icon = try icon.appIcon(self.app, window);
    c.gtk_window_set_icon_name(gtk_window, self.icon.name);

    // Apply background opacity if we have it
    if (app.config.@"background-opacity" < 1) {
        c.gtk_widget_set_opacity(@ptrCast(window), app.config.@"background-opacity");
    }

    // Use the new GTK4 header bar. We only create a header bar if we have
    // window decorations.
    if (app.config.@"window-decoration") {
        // gtk-titlebar can also be used to disable the header bar (but keep
        // the window manager's decorations).
        if (app.config.@"gtk-titlebar") {
            const header = c.gtk_header_bar_new();
            c.gtk_window_set_titlebar(gtk_window, header);
            {
                const btn = c.gtk_menu_button_new();
                c.gtk_widget_set_tooltip_text(btn, "Main Menu");
                c.gtk_menu_button_set_icon_name(@ptrCast(btn), "open-menu-symbolic");
                c.gtk_menu_button_set_menu_model(@ptrCast(btn), @ptrCast(@alignCast(app.menu)));
                c.gtk_header_bar_pack_end(@ptrCast(header), btn);
            }
            {
                const btn = c.gtk_button_new_from_icon_name("tab-new-symbolic");
                c.gtk_widget_set_tooltip_text(btn, "New Tab");
                c.gtk_header_bar_pack_end(@ptrCast(header), btn);
                _ = c.g_signal_connect_data(btn, "clicked", c.G_CALLBACK(&gtkTabNewClick), self, null, c.G_CONNECT_DEFAULT);
            }
        }
    } else {
        // Hide window decoration if configured. This has to happen before
        // `gtk_widget_show`.
        c.gtk_window_set_decorated(gtk_window, 0);
    }

    // Create a notebook to hold our tabs.
    const notebook_widget = c.gtk_notebook_new();
    const notebook: *c.GtkNotebook = @ptrCast(notebook_widget);
    self.notebook = notebook;
    c.gtk_notebook_set_tab_pos(notebook, c.GTK_POS_TOP);
    c.gtk_notebook_set_scrollable(notebook, 1);
    c.gtk_notebook_set_show_tabs(notebook, 0);
    c.gtk_notebook_set_show_border(notebook, 0);

    // This is important so the notebook expands to fit available space.
    // Otherwise, it will be zero/zero in the box below.
    c.gtk_widget_set_vexpand(notebook_widget, 1);
    c.gtk_widget_set_hexpand(notebook_widget, 1);

    // Create our box which will hold our widgets.
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);

    // In debug we show a warning. This is a really common issue where
    // people build from source in debug and performance is really bad.
    if (builtin.mode == .Debug) {
        const warning = c.gtk_label_new("⚠️ You're running a debug build of Ghostty! Performance will be degraded.");
        c.gtk_widget_set_margin_top(warning, 10);
        c.gtk_widget_set_margin_bottom(warning, 10);
        c.gtk_box_append(@ptrCast(box), warning);
    }
    c.gtk_box_append(@ptrCast(box), notebook_widget);

    // If we are in fullscreen mode, new windows start fullscreen.
    if (app.config.fullscreen) c.gtk_window_fullscreen(self.window);

    // All of our events
    _ = c.g_signal_connect_data(window, "close-request", c.G_CALLBACK(&gtkCloseRequest), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(window, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(notebook, "page-added", c.G_CALLBACK(&gtkPageAdded), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(notebook, "page-removed", c.G_CALLBACK(&gtkPageRemoved), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(notebook, "switch-page", c.G_CALLBACK(&gtkSwitchPage), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(notebook, "create-window", c.G_CALLBACK(&gtkNotebookCreateWindow), self, null, c.G_CONNECT_DEFAULT);

    // Our actions for the menu
    initActions(self);

    // The box is our main child
    c.gtk_window_set_child(gtk_window, box);

    // Show the window
    c.gtk_widget_show(window);
}

/// Sets up the GTK actions for the window scope. Actions are how GTK handles
/// menus and such. The menu is defined in App.zig but the action is defined
/// here. The string name binds them.
fn initActions(self: *Window) void {
    const actions = .{
        .{ "about", &gtkActionAbout },
        .{ "close", &gtkActionClose },
        .{ "new_window", &gtkActionNewWindow },
        .{ "new_tab", &gtkActionNewTab },
        .{ "toggle_inspector", &gtkActionToggleInspector },
    };

    inline for (actions) |entry| {
        const action = c.g_simple_action_new(entry[0], null);
        defer c.g_object_unref(action);
        _ = c.g_signal_connect_data(
            action,
            "activate",
            c.G_CALLBACK(entry[1]),
            self,
            null,
            c.G_CONNECT_DEFAULT,
        );
        c.g_action_map_add_action(@ptrCast(self.window), @ptrCast(action));
    }
}

pub fn deinit(self: *Window) void {
    self.icon.deinit(self.app);
    for (self.tabs.items) |tab| self.app.core_app.alloc.destroy(tab);
    self.tabs.deinit(self.app.core_app.alloc);
}

/// Add a new tab to this window.
pub fn newTab(self: *Window, parentSurface: ?*CoreSurface) !void {
    const alloc = self.app.core_app.alloc;
    const tab = try Tab.create(alloc, self, parentSurface);
    try self.tabs.append(alloc, tab);

    // TODO: When this is triggered through a GTK action, the new surface
    // redraws correctly. When it's triggered through keyboard shortcuts, it
    // does not (cursor doesn't blink) unless reactivated by refocusing.
}

pub fn removeTab(self: *Window, tab: *Tab) !void {
    // Remove the tab from our stored tabs.
    const tab_idx = for (self.tabs.items, 0..) |t, i| {
        if (t == tab) break i;
    } else null;

    // TODO: Shrink capacity?
    if (tab_idx) |idx| _ = self.tabs.orderedRemove(idx) else return error.TabNotFound;

    // Deallocate the tab
    self.app.core_app.alloc.destroy(tab);
}

/// Close the tab for the given notebook page. This will automatically
/// handle closing the window if there are no more tabs.
pub fn closeTab(self: *Window, tab: *Tab) void {
    const page = c.gtk_notebook_get_page(self.notebook, @ptrCast(tab.box)) orelse return;

    // Find page and tab which we're closing
    const page_idx = getNotebookPageIndex(page);

    // Remove the tab from our stored tabs.
    self.removeTab(tab) catch |err| {
        log.warn("tab {} not removable: {}", .{ page_idx, err });
        return;
    };

    c.gtk_notebook_remove_page(self.notebook, page_idx);

    const remaining = c.gtk_notebook_get_n_pages(self.notebook);
    switch (remaining) {
        // If we have no more tabs we close the window
        0 => c.gtk_window_destroy(self.window),

        // If we have one more tab we hide the tab bar
        1 => c.gtk_notebook_set_show_tabs(self.notebook, 0),

        else => {},
    }

    // If we have remaining tabs, we need to make sure we grab focus.
    if (remaining > 0) self.focusCurrentTab();
}

/// Close the surface. This surface must be definitely part of this window.
pub fn closeSurface(self: *Window, surface: *Surface) void {
    assert(surface.window == self);

    const alloc = surface.app.core_app.alloc;

    switch (surface.parent) {
        .tab => |tab| self.closeTab(tab),
        .paned => |paned_tuple| {
            const paned = paned_tuple[0];
            const position = paned_tuple[1];

            const sibling = switch (position) {
                .start => .{
                    switch (paned.child2) {
                        .surface => |s| s,
                        else => return,
                    },
                    c.gtk_paned_get_end_child(paned.paned),
                },
                .end => .{
                    switch (paned.child1) {
                        .surface => |s| s,
                        else => return,
                    },
                    c.gtk_paned_get_start_child(paned.paned),
                },
            };
            // TODO: Use destructuring syntax once it doesn't break ZLS
            const sibling_surface = sibling[0];
            const sibling_widget = sibling[1];

            // Keep explicit reference to sibling's gl_area, so it's not
            // destroyed when we remove it from GtkPaned.
            const sibling_object: *c.GObject = @ptrCast(sibling_widget);
            _ = c.g_object_ref(sibling_object);
            defer c.g_object_unref(sibling_object);

            // Remove reference on the surface we're closing
            surface.setParent(.none);

            // Remove children and kill Paned.
            paned.removeChildren();
            defer alloc.destroy(paned);

            switch (paned.parent) {
                .tab => |tab| {
                    // If parent of Paned we belong to is a tab, we can
                    // replace the child with the other surface
                    tab.removeChild();
                    tab.setChild(.{ .surface = sibling_surface });
                },
                .paned => |paned_paned| {
                    log.info("paned is nested, parent is paned. position={}", .{paned_paned[1]});
                },
                .none => {
                    log.info("paned has no parent", .{});
                },
            }
        },
        .none => {
            log.info("no parent, dude?!", .{});
        },
    }
}

/// Returns true if this window has any tabs.
pub fn hasTabs(self: *const Window) bool {
    return c.gtk_notebook_get_n_pages(self.notebook) > 1;
}

/// Go to the previous tab for a surface.
pub fn gotoPreviousTab(self: *Window, surface: *Surface) void {
    const page = c.gtk_notebook_get_page(self.notebook, @ptrCast(surface.tab.box)) orelse return;
    const page_idx = getNotebookPageIndex(page);

    // The next index is the previous or we wrap around.
    const next_idx = if (page_idx > 0) page_idx - 1 else next_idx: {
        const max = c.gtk_notebook_get_n_pages(self.notebook);
        break :next_idx max -| 1;
    };

    // Do nothing if we have one tab
    if (next_idx == page_idx) return;

    c.gtk_notebook_set_current_page(self.notebook, next_idx);
    self.focusCurrentTab();
}

/// Go to the next tab for a surface.
pub fn gotoNextTab(self: *Window, surface: *Surface) void {
    const page = c.gtk_notebook_get_page(self.notebook, @ptrCast(surface.tab.box)) orelse return;
    const page_idx = getNotebookPageIndex(page);
    const max = c.gtk_notebook_get_n_pages(self.notebook) -| 1;
    const next_idx = if (page_idx < max) page_idx + 1 else 0;
    if (next_idx == page_idx) return;

    c.gtk_notebook_set_current_page(self.notebook, next_idx);
    self.focusCurrentTab();
}

/// Go to the specific tab index.
pub fn gotoTab(self: *Window, n: usize) void {
    if (n == 0) return;
    const max = c.gtk_notebook_get_n_pages(self.notebook);
    const page_idx = std.math.cast(c_int, n - 1) orelse return;
    if (page_idx < max) {
        c.gtk_notebook_set_current_page(self.notebook, page_idx);
        self.focusCurrentTab();
    }
}

/// Toggle fullscreen for this window.
pub fn toggleFullscreen(self: *Window, _: configpkg.NonNativeFullscreen) void {
    const is_fullscreen = c.gtk_window_is_fullscreen(self.window);
    if (is_fullscreen == 0) {
        c.gtk_window_fullscreen(self.window);
    } else {
        c.gtk_window_unfullscreen(self.window);
    }
}

/// Grabs focus on the currently selected tab.
fn focusCurrentTab(self: *Window) void {
    const page_idx = c.gtk_notebook_get_current_page(self.notebook);
    const page = c.gtk_notebook_get_nth_page(self.notebook, page_idx);
    const tab: *Tab = @ptrCast(@alignCast(
        c.g_object_get_data(@ptrCast(page), Tab.GHOSTTY_TAB) orelse return,
    ));
    const gl_area = @as(*c.GtkWidget, @ptrCast(tab.focus_child.gl_area));
    _ = c.gtk_widget_grab_focus(gl_area);
}

// Note: we MUST NOT use the GtkButton parameter because gtkActionNewTab
// sends an undefined value.
fn gtkTabNewClick(_: *c.GtkButton, ud: ?*anyopaque) callconv(.C) void {
    const self: *Window = @ptrCast(@alignCast(ud orelse return));
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .new_tab = {} }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkPageAdded(
    _: *c.GtkNotebook,
    child: *c.GtkWidget,
    _: c.guint,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud.?);
    _ = self;
    _ = child;
}

fn gtkPageRemoved(
    _: *c.GtkNotebook,
    _: *c.GtkWidget,
    _: c.guint,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud.?);

    // Hide the tab bar if we only have one tab after removal
    const remaining = c.gtk_notebook_get_n_pages(self.notebook);
    if (remaining == 1) {
        c.gtk_notebook_set_show_tabs(self.notebook, 0);
    }
}

fn gtkSwitchPage(_: *c.GtkNotebook, page: *c.GtkWidget, _: usize, ud: ?*anyopaque) callconv(.C) void {
    const self = userdataSelf(ud.?);
    const gtk_label_box = @as(*c.GtkWidget, @ptrCast(c.gtk_notebook_get_tab_label(self.notebook, page)));
    const gtk_label = @as(*c.GtkLabel, @ptrCast(c.gtk_widget_get_first_child(gtk_label_box)));
    const label_text = c.gtk_label_get_text(gtk_label);
    c.gtk_window_set_title(self.window, label_text);
}

fn gtkNotebookCreateWindow(
    _: *c.GtkNotebook,
    page: *c.GtkWidget,
    ud: ?*anyopaque,
) callconv(.C) ?*c.GtkNotebook {
    // The tab for the page is stored in the widget data.
    const tab: *Tab = @ptrCast(@alignCast(
        c.g_object_get_data(@ptrCast(page), Tab.GHOSTTY_TAB) orelse return null,
    ));
    const surface: *Surface = tab.focus_child;

    const self = userdataSelf(ud.?);
    const alloc = self.app.core_app.alloc;

    // Create a new window
    const window = Window.create(alloc, self.app) catch |err| {
        log.warn("error creating new window error={}", .{err});
        return null;
    };

    // We need to update our surface to point to the new window and tab so that
    // events such as new tab go to the right window.
    surface.window = window;
    surface.tab = window.tabs.items[window.tabs.items.len - 1];

    return window.notebook;
}

fn gtkCloseRequest(v: *c.GtkWindow, ud: ?*anyopaque) callconv(.C) bool {
    _ = v;
    log.debug("window close request", .{});
    const self = userdataSelf(ud.?);

    // If none of our surfaces need confirmation, we can just exit.
    for (self.app.core_app.surfaces.items) |surface| {
        if (surface.window == self) {
            if (surface.core_surface.needsConfirmQuit()) break;
        }
    } else {
        c.gtk_window_destroy(self.window);
        return true;
    }

    // Setup our basic message
    const alert = c.gtk_message_dialog_new(
        self.window,
        c.GTK_DIALOG_MODAL,
        c.GTK_MESSAGE_QUESTION,
        c.GTK_BUTTONS_YES_NO,
        "Close this window?",
    );
    c.gtk_message_dialog_format_secondary_text(
        @ptrCast(alert),
        "All terminal sessions in this window will be terminated.",
    );

    // We want the "yes" to appear destructive.
    const yes_widget = c.gtk_dialog_get_widget_for_response(
        @ptrCast(alert),
        c.GTK_RESPONSE_YES,
    );
    c.gtk_widget_add_css_class(yes_widget, "destructive-action");

    // We want the "no" to be the default action
    c.gtk_dialog_set_default_response(
        @ptrCast(alert),
        c.GTK_RESPONSE_NO,
    );

    _ = c.g_signal_connect_data(alert, "response", c.G_CALLBACK(&gtkCloseConfirmation), self, null, c.G_CONNECT_DEFAULT);

    c.gtk_widget_show(alert);
    return true;
}

fn gtkCloseConfirmation(
    alert: *c.GtkMessageDialog,
    response: c.gint,
    ud: ?*anyopaque,
) callconv(.C) void {
    c.gtk_window_destroy(@ptrCast(alert));
    if (response == c.GTK_RESPONSE_YES) {
        const self = userdataSelf(ud.?);
        c.gtk_window_destroy(self.window);
    }
}

/// "destroy" signal for the window
fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    _ = v;
    log.debug("window destroy", .{});

    const self = userdataSelf(ud.?);
    const alloc = self.app.core_app.alloc;
    self.deinit();
    alloc.destroy(self);
}

fn getNotebookPageIndex(page: *c.GtkNotebookPage) c_int {
    var value: c.GValue = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&value);
    _ = c.g_value_init(&value, c.G_TYPE_INT);
    c.g_object_get_property(
        @ptrCast(@alignCast(page)),
        "position",
        &value,
    );

    return c.g_value_get_int(&value);
}

fn gtkActionAbout(
    _: *c.GSimpleAction,
    _: *c.GVariant,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *Window = @ptrCast(@alignCast(ud orelse return));

    c.gtk_show_about_dialog(
        self.window,
        "program-name",
        "Ghostty",
        "logo-icon-name",
        "com.mitchellh.ghostty",
        "title",
        "About Ghostty",
        "version",
        build_config.version_string.ptr,
        "website",
        "https://github.com/mitchellh/ghostty",
        @as(?*anyopaque, null),
    );
}

fn gtkActionClose(
    _: *c.GSimpleAction,
    _: *c.GVariant,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *Window = @ptrCast(@alignCast(ud orelse return));
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .close_surface = {} }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionNewWindow(
    _: *c.GSimpleAction,
    _: *c.GVariant,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *Window = @ptrCast(@alignCast(ud orelse return));
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .new_window = {} }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionNewTab(
    _: *c.GSimpleAction,
    _: *c.GVariant,
    ud: ?*anyopaque,
) callconv(.C) void {
    // We can use undefined because the button is not used.
    gtkTabNewClick(undefined, ud);
}

fn gtkActionToggleInspector(
    _: *c.GSimpleAction,
    _: *c.GVariant,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *Window = @ptrCast(@alignCast(ud orelse return));
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .inspector = .toggle }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

/// Returns the surface to use for an action.
fn actionSurface(self: *Window) ?*CoreSurface {
    const page_idx = c.gtk_notebook_get_current_page(self.notebook);
    const page = c.gtk_notebook_get_nth_page(self.notebook, page_idx);
    const tab: *Tab = @ptrCast(@alignCast(
        c.g_object_get_data(@ptrCast(page), Tab.GHOSTTY_TAB) orelse return null,
    ));
    return &tab.focus_child.core_surface;
}

fn userdataSelf(ud: *anyopaque) *Window {
    return @ptrCast(@alignCast(ud));
}

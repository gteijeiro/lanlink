#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* incoming_channel;
  gboolean incoming_ready;
  GQueue* incoming_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows) { gtk_window_present(GTK_WINDOW(windows->data)); return; }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "lanlink");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "lanlink");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->incoming_channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)), "lanlink/incoming", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->incoming_channel, [](FlMethodChannel* channel, FlMethodCall* call, gpointer data) {
    auto* app = MY_APPLICATION(data);
    const gchar* method = fl_method_call_get_name(call);
    if (g_strcmp0(method, "drain") == 0) {
      app->incoming_ready = TRUE;
      g_autoptr(FlValue) empty = fl_value_new_list();
      fl_method_call_respond_success(call, empty, nullptr);
      while (!g_queue_is_empty(app->incoming_arguments)) {
        auto* args = static_cast<FlValue*>(g_queue_pop_head(app->incoming_arguments));
        fl_method_channel_invoke_method(channel, "arguments", args, nullptr, nullptr, nullptr);
        fl_value_unref(args);
      }
    } else if (g_strcmp0(method, "release") == 0) { fl_method_call_respond_success(call, nullptr, nullptr); }
    else { fl_method_call_respond_not_implemented(call, nullptr); }
  }, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// GApplication forwards subsequent invocations to the same user's primary process.
static int my_application_command_line(GApplication* application, GApplicationCommandLine* command_line) {
  auto* self = MY_APPLICATION(application);
  int count = 0;
  g_auto(GStrv) args = g_application_command_line_get_arguments(command_line, &count);
  if (self->dart_entrypoint_arguments == nullptr) {
    self->dart_entrypoint_arguments = g_strdupv(args + 1);
  } else if (count > 1) {
    FlValue* values = fl_value_new_list();
    for (int i = 1; i < count && i <= 102; ++i) fl_value_append_take(values, fl_value_new_string(args[i]));
    if (self->incoming_ready && self->incoming_channel) {
      fl_method_channel_invoke_method(self->incoming_channel, "arguments", values, nullptr, nullptr, nullptr);
      fl_value_unref(values);
    } else { g_queue_push_tail(self->incoming_arguments, values); }
  }
  g_application_activate(application);
  return 0;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->incoming_channel);
  if (self->incoming_arguments) { g_queue_free_full(self->incoming_arguments, [](gpointer value) { fl_value_unref(static_cast<FlValue*>(value)); }); self->incoming_arguments = nullptr; }
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) { self->incoming_arguments = g_queue_new(); }

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE, nullptr));
}

#ifndef webview_plus_METHOD_CHANNEL_UTILS_H_
#define webview_plus_METHOD_CHANNEL_UTILS_H_

#include <flutter_linux/flutter_linux.h>

FlValue *map_lookup(FlValue *map, const gchar *key);
const gchar *map_lookup_string(FlValue *map, const gchar *key);
gboolean map_lookup_bool(FlValue *map, const gchar *key, gboolean fallback);
double map_lookup_double(FlValue *map, const gchar *key, double fallback);
gint64 map_lookup_int(FlValue *map, const gchar *key, gint64 fallback);

FlMethodResponse *success_response(FlValue *value = nullptr);
FlMethodResponse *error_response(const gchar *code, const gchar *message);
void respond(FlMethodCall *method_call, FlMethodResponse *response);

#endif  // webview_plus_METHOD_CHANNEL_UTILS_H_

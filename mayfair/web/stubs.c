/*
    Stand-ins, for the browser, for the AccessKit and litehtml functions Mayfair's code calls.
    Written by make-stubs.py: run it again, rather than editing this, when the code calls another.
*/
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "accesskit.h"
#include "litehtml_shim.h"

void accesskit_action_request_free(struct accesskit_action_request *request) { }
struct accesskit_affine accesskit_affine_scale(double s) { static struct accesskit_affine none; return none; }
void accesskit_node_add_action(struct accesskit_node *node, accesskit_action action) { }
struct accesskit_node_ids accesskit_node_children( const struct accesskit_node *node) { static struct accesskit_node_ids none; return none; }
struct accesskit_node * accesskit_node_new(accesskit_role role) { static struct accesskit_node * none; return none; }
void accesskit_node_push_child(struct accesskit_node *node, accesskit_node_id item) { }
accesskit_role accesskit_node_role(const struct accesskit_node *node) { static accesskit_role none; return none; }
void accesskit_node_set_bounds(struct accesskit_node *node, struct accesskit_rect value) { }
void accesskit_node_set_character_lengths(struct accesskit_node *node, size_t length, const uint8_t *values) { }
void accesskit_node_set_character_positions(struct accesskit_node *node, size_t length, const float *values) { }
void accesskit_node_set_character_widths(struct accesskit_node *node, size_t length, const float *values) { }
void accesskit_node_set_clips_children(struct accesskit_node *node) { }
void accesskit_node_set_column_count(struct accesskit_node *node, size_t value) { }
void accesskit_node_set_column_index(struct accesskit_node *node, size_t value) { }
void accesskit_node_set_description_with_length(struct accesskit_node *node, const char *value, size_t length) { }
void accesskit_node_set_disabled(struct accesskit_node *node) { }
void accesskit_node_set_expanded(struct accesskit_node *node, bool value) { }
void accesskit_node_set_has_popup(struct accesskit_node *node, accesskit_has_popup value) { }
void accesskit_node_set_label_with_length(struct accesskit_node *node, const char *value, size_t length) { }
void accesskit_node_set_level(struct accesskit_node *node, size_t value) { }
void accesskit_node_set_max_numeric_value(struct accesskit_node *node, double value) { }
void accesskit_node_set_min_numeric_value(struct accesskit_node *node, double value) { }
void accesskit_node_set_multiselectable(struct accesskit_node *node) { }
void accesskit_node_set_next_on_line(struct accesskit_node *node, accesskit_node_id value) { }
void accesskit_node_set_numeric_value(struct accesskit_node *node, double value) { }
void accesskit_node_set_numeric_value_step(struct accesskit_node *node, double value) { }
void accesskit_node_set_placeholder_with_length(struct accesskit_node *node, const char *value, size_t length) { }
void accesskit_node_set_position_in_set(struct accesskit_node *node, size_t value) { }
void accesskit_node_set_previous_on_line(struct accesskit_node *node, accesskit_node_id value) { }
void accesskit_node_set_read_only(struct accesskit_node *node) { }
void accesskit_node_set_row_count(struct accesskit_node *node, size_t value) { }
void accesskit_node_set_row_index(struct accesskit_node *node, size_t value) { }
void accesskit_node_set_scroll_x(struct accesskit_node *node, double value) { }
void accesskit_node_set_scroll_x_max(struct accesskit_node *node, double value) { }
void accesskit_node_set_scroll_x_min(struct accesskit_node *node, double value) { }
void accesskit_node_set_scroll_y(struct accesskit_node *node, double value) { }
void accesskit_node_set_scroll_y_max(struct accesskit_node *node, double value) { }
void accesskit_node_set_scroll_y_min(struct accesskit_node *node, double value) { }
void accesskit_node_set_selected(struct accesskit_node *node, bool value) { }
void accesskit_node_set_size_of_set(struct accesskit_node *node, size_t value) { }
void accesskit_node_set_text_direction(struct accesskit_node *node, accesskit_text_direction value) { }
void accesskit_node_set_text_selection(struct accesskit_node *node, struct accesskit_text_selection value) { }
void accesskit_node_set_toggled(struct accesskit_node *node, accesskit_toggled value) { }
void accesskit_node_set_transform(struct accesskit_node *node, struct accesskit_affine value) { }
void accesskit_node_set_value_with_length(struct accesskit_node *node, const char *value, size_t length) { }
void accesskit_node_set_word_starts(struct accesskit_node *node, size_t length, const uint8_t *values) { }
struct accesskit_tree_info * accesskit_tree_info_new(accesskit_node_id root) { static struct accesskit_tree_info * none; return none; }
void accesskit_tree_info_set_toolkit_name_with_length( struct accesskit_tree_info *tree, const char *toolkit_name, size_t length) { }
void accesskit_tree_update_push_node(struct accesskit_tree_update *update, accesskit_node_id id, struct accesskit_node *node) { }
void accesskit_tree_update_set_tree_info(struct accesskit_tree_update *update, struct accesskit_tree_info *tree) { }
struct accesskit_tree_update * accesskit_tree_update_with_focus( accesskit_node_id focus) { static struct accesskit_tree_update * none; return none; }
lh_document* lh_document_create(const char* html, size_t length, const lh_callbacks* callbacks, const char* user_css) { static lh_document* none; return none; }
void lh_document_destroy(lh_document* doc) { }
void lh_document_draw(lh_document* doc, uintptr_t hdc, float x, float y, const lh_position* clip) { }
bool lh_document_find(lh_document* doc, const char* selector, lh_position* where) { static bool none; return none; }
float lh_document_height(lh_document* doc) { static float none; return none; }
bool lh_document_media_changed(lh_document* doc) { static bool none; return none; }
bool lh_document_mouse_cancel(lh_document* doc) { static bool none; return none; }
bool lh_document_mouse_down(lh_document* doc, float x, float y) { static bool none; return none; }
bool lh_document_mouse_leave(lh_document* doc) { static bool none; return none; }
bool lh_document_mouse_over(lh_document* doc, float x, float y) { static bool none; return none; }
bool lh_document_mouse_up(lh_document* doc, float x, float y) { static bool none; return none; }
float lh_document_render(lh_document* doc, float max_width) { static float none; return none; }
float lh_document_width(lh_document* doc) { static float none; return none; }
const char* lh_string_get(const lh_string* s, size_t* length) { static const char* none; return none; }
void lh_string_set(lh_string* s, const char* text, size_t length) { }

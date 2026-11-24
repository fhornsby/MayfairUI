/*
    Checks what source/mayfair/media/gstreamer/gst.d declares by hand against GStreamer's own
    headers: every constant, and the layout of each struct it reads. Run by check-abi.sh, after a
    GStreamer upgrade or on a new platform; it compiles only if they agree.
*/
#include <stddef.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>

#define SAME(a, b) _Static_assert((a) == (b), #a " isn't " #b ": update gst.d")

SAME(GST_STATE_NULL, 1); SAME(GST_STATE_READY, 2); SAME(GST_STATE_PAUSED, 3); SAME(GST_STATE_PLAYING, 4);
SAME(GST_STATE_CHANGE_FAILURE, 0); SAME(GST_STATE_CHANGE_SUCCESS, 1); SAME(GST_STATE_CHANGE_ASYNC, 2);
SAME(GST_STATE_CHANGE_NO_PREROLL, 3);
SAME(GST_FORMAT_TIME, 3);
SAME(GST_SEEK_FLAG_FLUSH, 1); SAME(GST_SEEK_FLAG_ACCURATE, 2); SAME(GST_SEEK_FLAG_KEY_UNIT, 4);
SAME(GST_MAP_READ, 1); SAME(GST_FLOW_OK, 0);
SAME(GST_MESSAGE_EOS, 1 << 0); SAME(GST_MESSAGE_ERROR, 1 << 1); SAME(GST_MESSAGE_WARNING, 1 << 2);
SAME(GST_MESSAGE_TAG, 1 << 4); SAME(GST_MESSAGE_BUFFERING, 1 << 5); SAME(GST_MESSAGE_STATE_CHANGED, 1 << 6);
SAME(GST_MESSAGE_CLOCK_LOST, 1 << 10); SAME(GST_MESSAGE_APPLICATION, 1 << 14);
SAME(GST_MESSAGE_DURATION_CHANGED, 1 << 18); SAME(GST_MESSAGE_LATENCY, 1 << 19); SAME(GST_MESSAGE_ASYNC_DONE, 1 << 21);
SAME(GST_RESOURCE_ERROR_NOT_FOUND, 3); SAME(GST_RESOURCE_ERROR_OPEN_READ, 5); SAME(GST_RESOURCE_ERROR_READ, 9);
SAME(GST_RESOURCE_ERROR_NOT_AUTHORIZED, 15);
SAME(GST_STREAM_ERROR_TYPE_NOT_FOUND, 4); SAME(GST_STREAM_ERROR_WRONG_TYPE, 5); SAME(GST_STREAM_ERROR_CODEC_NOT_FOUND, 6);
SAME(GST_STREAM_ERROR_DECODE, 7); SAME(GST_STREAM_ERROR_DEMUX, 9); SAME(GST_STREAM_ERROR_FORMAT, 11);
SAME(GST_CORE_ERROR_MISSING_PLUGIN, 12);

SAME(offsetof(GstMessage, type), 64); SAME(offsetof(GstMessage, src), 80);
SAME(sizeof(GstMapInfo), 104); SAME(offsetof(GstMapInfo, data), 16); SAME(offsetof(GstMapInfo, size), 24);
SAME(offsetof(GstAppSinkCallbacks, eos), 0); SAME(offsetof(GstAppSinkCallbacks, new_preroll), 8);
SAME(offsetof(GstAppSinkCallbacks, new_sample), 16);
_Static_assert(sizeof(GstAppSinkCallbacks) <= 56, "GstAppSinkCallbacks has grown: make gst.d's as big");
SAME(offsetof(GError, domain), 0); SAME(offsetof(GError, code), 4); SAME(offsetof(GError, message), 8);

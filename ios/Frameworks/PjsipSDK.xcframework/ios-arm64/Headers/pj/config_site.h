#ifndef __PJ_CONFIG_SITE_H__
#define __PJ_CONFIG_SITE_H__

#define PJ_CONFIG_IPHONE 1

/* All Apple ARM/x86 targets are little-endian */
#define PJ_IS_LITTLE_ENDIAN 1
#define PJ_IS_BIG_ENDIAN 0
#define PJ_HAS_SSL_SOCK 1
#define PJMEDIA_HAS_OPUS_CODEC 1

/* Audio-only: disable video */
#define PJMEDIA_HAS_VIDEO 0
#define PJMEDIA_HAS_OPENH264_CODEC 0
#define PJMEDIA_HAS_VPX_CODEC 0

/* Codec config */
#define PJMEDIA_HAS_G711_CODEC 1
#define PJMEDIA_HAS_GSM_CODEC 1
#define PJMEDIA_HAS_ILBC_CODEC 1
#define PJMEDIA_HAS_SPEEX_CODEC 1

/* WebSocket transport for FreeSWITCH WSS */
#define PJ_WEBSOCK_MAX_FRAME_LEN 65536

#include <pj/config_site_sample.h>

#endif /* __PJ_CONFIG_SITE_H__ */

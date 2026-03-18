#define PJ_CONFIG_ANDROID 1
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

#include <pj/config_site_sample.h>

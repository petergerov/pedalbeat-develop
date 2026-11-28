#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SolititoORTSession SolititoORTSession;

/// Load Solitito chord ONNX. Returns NULL on failure.
SolititoORTSession *solitito_ort_create(const char *model_path);

void solitito_ort_destroy(SolititoORTSession *session);

/// Run one window. `features` is 48×168 row-major. Outputs root(13), quality(11), pitch(12).
/// Returns 0 on success.
int solitito_ort_predict(SolititoORTSession *session,
                         const float *features,
                         float *root13,
                         float *qual11,
                         float *pitch12);

#ifdef __cplusplus
}
#endif

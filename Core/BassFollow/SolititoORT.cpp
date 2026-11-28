#include "SolititoORT.h"

#include <array>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "onnxruntime_cxx_api.h"

struct SolititoORTSession {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "solitito"};
    Ort::SessionOptions opts;
    std::unique_ptr<Ort::Session> session;
    Ort::AllocatorWithDefaultOptions alloc;
    std::string inputName;
    std::array<std::string, 3> outputNames;
};

SolititoORTSession *solitito_ort_create(const char *model_path) {
    if (!model_path) return nullptr;
    try {
        auto *s = new SolititoORTSession();
        s->opts.SetIntraOpNumThreads(1);
        s->opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        s->session = std::make_unique<Ort::Session>(s->env, model_path, s->opts);

        Ort::AllocatedStringPtr in = s->session->GetInputNameAllocated(0, s->alloc);
        s->inputName = in.get();
        for (size_t i = 0; i < 3 && i < s->session->GetOutputCount(); ++i) {
            Ort::AllocatedStringPtr out = s->session->GetOutputNameAllocated(i, s->alloc);
            s->outputNames[i] = out.get();
        }
        return s;
    } catch (...) {
        return nullptr;
    }
}

void solitito_ort_destroy(SolititoORTSession *session) {
    delete session;
}

int solitito_ort_predict(SolititoORTSession *session,
                         const float *features,
                         float *root13,
                         float *qual11,
                         float *pitch12) {
    if (!session || !features || !root13 || !qual11 || !pitch12) return -1;
    try {
        const std::array<int64_t, 3> shape{1, 48, 168};
        Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        std::vector<float> buf(features, features + 48 * 168);
        Ort::Value input = Ort::Value::CreateTensor<float>(
            mem, buf.data(), buf.size(), shape.data(), shape.size());

        const char *inNames[] = {session->inputName.c_str()};
        const char *outNames[] = {
            session->outputNames[0].c_str(),
            session->outputNames[1].c_str(),
            session->outputNames[2].c_str(),
        };

        auto outputs = session->session->Run(
            Ort::RunOptions{nullptr}, inNames, &input, 1, outNames, 3);

        auto take = [&](const char *name, float *dst, size_t n, size_t fallbackIndex) {
            for (size_t i = 0; i < outputs.size(); ++i) {
                if (session->outputNames[i] == name) {
                    std::memcpy(dst, outputs[i].GetTensorMutableData<float>(), n * sizeof(float));
                    return;
                }
            }
            if (fallbackIndex < outputs.size()) {
                std::memcpy(dst, outputs[fallbackIndex].GetTensorMutableData<float>(), n * sizeof(float));
            }
        };
        take("root_logits", root13, 13, 0);
        take("quality_logits", qual11, 11, 1);
        take("pitch_logits", pitch12, 12, 2);
        return 0;
    } catch (...) {
        return -2;
    }
}

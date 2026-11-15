#include "flutter_window.h"

#include <optional>
#include <sstream>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  incoming_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "lanlink/incoming", &flutter::StandardMethodCodec::GetInstance());
  incoming_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "drain") {
      incoming_ready_ = true;
      result->Success(flutter::EncodableValue(flutter::EncodableList{}));
      if (!pending_arguments_.empty()) {
        flutter::EncodableList values;
        for (const auto& value : pending_arguments_) values.emplace_back(value);
        pending_arguments_.clear();
        incoming_channel_->InvokeMethod("arguments", std::make_unique<flutter::EncodableValue>(values));
      }
    } else if (call.method_name() == "release") { result->Success(); }
    else { result->NotImplemented(); }
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  incoming_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (message == WM_COPYDATA && incoming_channel_) {
    const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (data && data->dwData == 0x4c4c5348 && data->cbData > 0 && data->cbData <= 65536 && data->lpData) {
      std::string payload(static_cast<const char*>(data->lpData), data->cbData - 1);
      std::istringstream stream(payload);
      flutter::EncodableList values;
      for (std::string value; std::getline(stream, value);) {
        if (values.size() >= 102) break;
        if (incoming_ready_) values.emplace_back(value); else pending_arguments_.push_back(value);
      }
      if (!values.empty()) incoming_channel_->InvokeMethod("arguments", std::make_unique<flutter::EncodableValue>(values));
      return TRUE;
    }
  }
  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

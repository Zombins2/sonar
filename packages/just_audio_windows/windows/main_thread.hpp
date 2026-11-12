// Sonar patch: runs work on the Flutter platform (main) thread.
//
// WinRT raises MediaPlayer and SMTC events on worker threads, but Flutter's
// platform channels must only be used from the platform thread; sending from
// elsewhere can drop messages or crash. Post() hands the work to the window's
// message loop instead.
#pragma once

#ifndef SONAR_MAIN_THREAD_MESSAGE
#error "Define SONAR_MAIN_THREAD_MESSAGE (a name unique to this plugin) before including main_thread.hpp"
#endif

#include <windows.h>

#include <flutter/plugin_registrar_windows.h>

#include <deque>
#include <functional>
#include <mutex>
#include <optional>

class MainThread {
 public:
  static void Init(flutter::PluginRegistrarWindows* registrar) {
    auto& s = State();
    s.thread = GetCurrentThreadId();
    // Unique per plugin: each plugin DLL has its own copy of this queue, and
    // the first delegate to answer a message stops it reaching the others.
    s.message = RegisterWindowMessageW(SONAR_MAIN_THREAD_MESSAGE);
    // The view isn't inside the app's window yet while plugins register, so
    // the window to post to is looked up at each Post.
    s.view = registrar->GetView();
    registrar->RegisterTopLevelWindowProcDelegate(
        [](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
          if (message != State().message) return std::nullopt;
          Drain();
          return 0;
        });
  }

  // Runs |work| now when already on the main thread, otherwise queues it.
  static void Post(std::function<void()> work) {
    auto& s = State();
    HWND window = s.view == nullptr ? nullptr : GetAncestor(s.view->GetNativeWindow(), GA_ROOT);
    if (GetCurrentThreadId() == s.thread || window == nullptr) {
      work();
      return;
    }
    {
      std::lock_guard<std::mutex> lock(s.mutex);
      s.queue.push_back(std::move(work));
    }
    PostMessageW(window, s.message, 0, 0);
  }

 private:
  struct Shared {
    DWORD thread = 0;
    UINT message = 0;
    flutter::FlutterView* view = nullptr;
    std::mutex mutex;
    std::deque<std::function<void()>> queue;
  };

  static Shared& State() {
    static Shared shared;
    return shared;
  }

  static void Drain() {
    auto& s = State();
    std::deque<std::function<void()>> work;
    {
      std::lock_guard<std::mutex> lock(s.mutex);
      work.swap(s.queue);
    }
    for (auto& w : work) w();
  }
};

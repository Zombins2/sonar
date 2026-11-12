package com.sonar.sonar

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service needs its own activity so the Flutter engine outlives the UI.
class MainActivity : AudioServiceActivity()

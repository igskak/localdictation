// Reports which MVP languages Apple can recognize *on this Mac, offline*.
//
// Run directly, no project build required:
//
//     swift Tools/probe_speech_models.swift
//
// `available` without `onDevice` means the recognizer works only by sending
// audio to Apple's servers, which this product never does. Treat such a
// language as unsupported, not as degraded.
//
// Offline assets are not fetched by adding a language under
// General → Language & Region. They arrive via Keyboard → Dictation → Languages.
import Foundation
import Speech

let locales = ["de-DE", "en-US", "ru-RU", "uk-UA"]
var offline: [String] = []

print("locale   on-device  available")
for identifier in locales {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) else {
        print("\(identifier)  —          no recognizer")
        continue
    }
    let onDevice = recognizer.supportsOnDeviceRecognition
    if onDevice { offline.append(identifier) }
    print("\(identifier)  \(onDevice ? "yes      " : "NO       ")  \(recognizer.isAvailable)")
}

print("\nUsable offline: \(offline.isEmpty ? "none" : offline.joined(separator: ", "))")
if offline.count < locales.count {
    print("Missing assets: add the languages under System Settings →")
    print("Keyboard → Dictation → Languages, then re-run. Download takes a few minutes.")
}

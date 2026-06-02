# Jarvis

A voice app for the Jarvis agent: hold to talk, and Jarvis replies in voice through a 3D energy orb.

- **UI:** SwiftUI + SceneKit (voice-reactive orb)
- **Voice:** on-device ElevenLabs STT (`scribe_v1`) + TTS (`eleven_multilingual_v2`)
- **Transport:** WebSocket to the Jarvis bridge at `wss://sirjarvis.ngrok.app/ws`
- **Project:** generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`

## Setup
1. Copy the secrets template and fill it in:
   ```sh
   cp Secrets.xcconfig.example Secrets.xcconfig
   # then edit Secrets.xcconfig: ELEVENLABS_API_KEY + JARVIS_WS_TOKEN
   ```
2. (Only if `project.yml` changed) regenerate the Xcode project:
   ```sh
   xcodegen generate
   ```
3. Open `Jarvis.xcodeproj`, set your signing **Team**, then build & run.

> `Secrets.xcconfig` is gitignored — your keys never get committed.

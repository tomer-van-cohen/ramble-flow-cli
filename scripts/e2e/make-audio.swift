// Test helper: builds synthetic recordings from `say` clips with AVFoundation.
//   swift make-audio.swift loop <clip.m4a> <minutes> <out.m4a>   repeat a clip with 2 s pauses
//   swift make-audio.swift qta <in.m4a> <out.qta>                 rewrap as a QuickTime movie (what Voice Memos writes)
import AVFoundation

let args = CommandLine.arguments
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }

func export(_ asset: AVAsset, to url: URL, type: AVFileType, preset: String) {
    try? FileManager.default.removeItem(at: url)
    guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { fail("no export session") }
    session.outputURL = url
    session.outputFileType = type
    let done = DispatchSemaphore(value: 0)
    session.exportAsynchronously { done.signal() }
    done.wait()
    if session.status != .completed { fail("export failed: \(String(describing: session.error))") }
}

switch args.count > 1 ? args[1] : "" {
case "loop":
    guard args.count == 5, let minutes = Double(args[3]) else { fail("usage: loop <clip> <minutes> <out>") }
    let clip = AVURLAsset(url: URL(fileURLWithPath: args[2]))
    guard let track = clip.tracks(withMediaType: .audio).first else { fail("no audio") }
    let composition = AVMutableComposition()
    let out = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    var cursor = CMTime.zero
    let gap = CMTime(seconds: 2, preferredTimescale: 600)
    let target = CMTime(seconds: minutes * 60, preferredTimescale: 600)
    while cursor < target {
        try! out.insertTimeRange(CMTimeRange(start: .zero, duration: clip.duration), of: track, at: cursor)
        cursor = cursor + clip.duration
        out.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: gap))
        cursor = cursor + gap
    }
    export(composition, to: URL(fileURLWithPath: args[4]), type: .m4a, preset: AVAssetExportPresetAppleM4A)
case "qta":
    guard args.count == 4 else { fail("usage: qta <in> <out>") }
    let staging = URL(fileURLWithPath: args[3] + ".mov")
    export(AVURLAsset(url: URL(fileURLWithPath: args[2])), to: staging, type: .mov, preset: AVAssetExportPresetPassthrough)
    try? FileManager.default.removeItem(atPath: args[3])
    try! FileManager.default.moveItem(at: staging, to: URL(fileURLWithPath: args[3]))
default:
    fail("usage: make-audio.swift loop|qta …")
}

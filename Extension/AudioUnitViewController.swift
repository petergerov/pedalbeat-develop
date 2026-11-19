import CoreAudioKit
import SwiftUI

#if os(macOS)
typealias PlatformHostingController = NSHostingController
#else
typealias PlatformHostingController = UIHostingController
#endif

/// Extension principal class: creates the audio unit and hosts the SwiftUI UI.
public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    nonisolated(unsafe) var audioUnit: PedalBeatAudioUnit?
    private var hosting: PlatformHostingController<MainView>?

    #if os(macOS)
    public override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nil, bundle: Bundle(for: AudioUnitViewController.self))
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 620))
    }
    #endif

    public override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 980, height: 620)
        if audioUnit != nil { attachUI() }
    }

    nonisolated public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try PedalBeatAudioUnit(componentDescription: componentDescription, options: [])
        audioUnit = au
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.attachUI()
        }
        return au
    }

    private func attachUI() {
        guard hosting == nil, let au = audioUnit else { return }
        let model = PedalViewModel(audioUnit: au)
        let hc = PlatformHostingController(rootView: MainView(model: model))
        addChild(hc)
        hc.view.frame = view.bounds
        #if os(macOS)
        hc.view.autoresizingMask = [.width, .height]
        #else
        hc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hc.view.backgroundColor = .clear
        #endif
        view.addSubview(hc.view)
        #if os(iOS)
        hc.didMove(toParent: self)
        #endif
        hosting = hc
    }
}

//
//  MusicVisualizer.swift
//  HeyNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Cocoa
import SwiftUI

class AudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var isPlaying: Bool = true
    private var reduceMotion = false
    private var animationTimer: Timer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    deinit {
        animationTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimationActivity()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateAnimationActivity()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimationActivity()
    }

    private func setupBars() {
        let barWidth: CGFloat = 2
        let barCount = 4
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            barLayer.backgroundColor = NSColor.white.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            barLayer.path = path.cgPath
            barLayer.transform = CATransform3DMakeScale(1, 0.35, 1)
            barLayers.append(barLayer)
            layer?.addSublayer(barLayer)
        }
    }
    
    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateBars()
        }
    }
    
    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        resetBars()
    }
    
    private func updateBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for barLayer in barLayers {
            // A timer can fire before or after the preceding animation ends.
            // Continue from the displayed value and keep the model at its target.
            let currentScale = (barLayer.presentation()?.value(forKeyPath: "transform.scale.y") as? NSNumber)?.doubleValue
                ?? (barLayer.value(forKeyPath: "transform.scale.y") as? NSNumber)?.doubleValue
                ?? 0.35
            let targetScale = CGFloat.random(in: 0.35 ... 1.0)
            barLayer.transform = CATransform3DMakeScale(1, targetScale, 1)
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = currentScale
            animation.toValue = targetScale
            animation.duration = 0.3
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            barLayer.add(animation, forKey: "scaleY")
        }
        CATransaction.commit()
    }
    
    private func resetBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for barLayer in barLayers {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, 0.35, 1)
        }
        CATransaction.commit()
    }
    
    func setPlaying(_ playing: Bool, reduceMotion: Bool = false) {
        isPlaying = playing
        self.reduceMotion = reduceMotion
        updateAnimationActivity()
    }

    private func updateAnimationActivity() {
        if isPlaying && !reduceMotion && window != nil && !isHiddenOrHasHiddenAncestor {
            startAnimating()
        } else {
            stopAnimating()
        }
    }
}

struct AudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.setPlaying(isPlaying, reduceMotion: reduceMotion)
        return spectrum
    }
    
    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ nsView: AudioSpectrum, coordinator: ()) {
        nsView.setPlaying(false)
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}

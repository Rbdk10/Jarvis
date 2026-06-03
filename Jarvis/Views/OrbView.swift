import SwiftUI
import SceneKit
import simd

/// A floating J.A.R.V.I.S.-style energy sphere: a dense weave of fine, curved glowing
/// filaments wrapping a blazing molten core, with a drifting spark halo and soft HDR
/// bloom so the whole thing reads as floating light — not solid plastic. It drifts
/// gently at rest and brightens / pulses with `level` (0...1) while Jarvis speaks.
/// `accent` tints it (amber when speaking, blue while listening).
struct OrbView: UIViewRepresentable {
    var level: Float
    var accent: UIColor

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.scene = context.coordinator.buildScene()
        view.allowsCameraControl = false
        view.isUserInteractionEnabled = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.update(level: level, accent: accent)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private let drift = SCNNode()        // slow floaty rotation
        private let filaments = SCNNode()
        private let core = SCNNode()
        private let glow = SCNNode()
        private let coreMat = SCNMaterial()
        private let glowMat = SCNMaterial()
        private let filamentMat = SCNMaterial()
        private let halo = SCNParticleSystem()

        private let R: Float = 1.32          // sphere radius
        private let strandCount = 280
        private let pointsPerStrand = 18
        private var tick: Float = 0

        func buildScene() -> SCNScene {
            let scene = SCNScene()

            let cam = SCNNode()
            cam.camera = SCNCamera()
            cam.position = SCNVector3(0, 0, 6)
            // HDR bloom — this is what makes the emissive filaments and core glow softly
            // and "float" rather than look like hard plastic geometry.
            if let c = cam.camera {
                c.wantsHDR = true
                c.bloomIntensity = 1.4
                c.bloomThreshold = 0.25
                c.bloomBlurRadius = 14
                c.wantsExposureAdaptation = false
            }
            scene.rootNode.addChildNode(cam)

            // Blazing core — bright near-white centre.
            let coreGeo = SCNSphere(radius: 0.5)
            coreGeo.segmentCount = 96
            coreMat.lightingModel = .constant
            coreMat.diffuse.contents = UIColor.black
            coreMat.emission.contents = UIColor(red: 1.0, green: 0.95, blue: 0.85, alpha: 1)
            coreMat.emission.intensity = 1.6
            coreGeo.firstMaterial = coreMat
            core.geometry = coreGeo

            // Soft inner glow shell.
            let glowGeo = SCNSphere(radius: 0.92)
            glowGeo.segmentCount = 64
            glowMat.lightingModel = .constant
            glowMat.diffuse.contents = UIColor.clear
            glowMat.emission.contents = UIColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1)
            glowMat.emission.intensity = 0.5
            glowMat.transparency = 0.5
            glowMat.blendMode = .add
            glowMat.isDoubleSided = true
            glowMat.writesToDepthBuffer = false
            glowGeo.firstMaterial = glowMat
            glow.geometry = glowGeo

            // Filament weave (one combined line geometry of curved strands on the sphere).
            filamentMat.lightingModel = .constant
            filamentMat.diffuse.contents = UIColor.black
            filamentMat.emission.contents = UIColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1)
            filamentMat.emission.intensity = 1.1
            filamentMat.blendMode = .add
            filamentMat.writesToDepthBuffer = false
            let geo = buildFilamentGeometry()
            geo.firstMaterial = filamentMat
            filaments.geometry = geo

            // Drifting spark halo for shimmer + motion.
            halo.birthRate = 360
            halo.particleLifeSpan = 2.4
            halo.particleSize = 0.014
            halo.particleColor = UIColor(red: 1.0, green: 0.7, blue: 0.3, alpha: 1)
            halo.emitterShape = SCNSphere(radius: CGFloat(R))
            halo.birthLocation = .surface
            halo.particleVelocity = 0.05
            halo.particleVelocityVariation = 0.06
            halo.isAffectedByGravity = false
            halo.blendMode = .additive
            halo.isLightingEnabled = false

            drift.addChildNode(core)
            drift.addChildNode(glow)
            drift.addChildNode(filaments)
            filaments.addParticleSystem(halo)
            scene.rootNode.addChildNode(drift)

            // Gentle, perpetual float — slow multi-axis drift so it never feels static.
            drift.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 44)))
            filaments.runAction(.repeatForever(.rotateBy(x: .pi * 2, y: 0, z: 0, duration: 70)))
            core.runAction(.repeatForever(.sequence([
                .scale(to: 1.05, duration: 2.2), .scale(to: 1.0, duration: 2.2)
            ])))

            return scene
        }

        /// Build curved filament strands woven over the sphere as one `.line` geometry.
        private func buildFilamentGeometry() -> SCNGeometry {
            let golden = Float.pi * (3 - sqrtf(5))
            var verts: [SCNVector3] = []
            var indices: [Int32] = []
            for i in 0..<strandCount {
                let y = 1 - (Float(i) / Float(strandCount - 1)) * 2
                let r = sqrtf(max(0, 1 - y * y))
                let theta = golden * Float(i)
                let dir = simd_float3(r * cosf(theta), y, r * sinf(theta))     // start direction
                let ref: simd_float3 = abs(dir.y) < 0.9 ? simd_float3(0, 1, 0) : simd_float3(1, 0, 0)
                let tangent = simd_normalize(simd_cross(dir, ref))
                let binormal = simd_normalize(simd_cross(dir, tangent))
                let arc = 0.7 + Float(i % 5) * 0.22            // angular length of the strand
                let curl = 1.4 + Float(i % 7) * 0.5
                let phase = theta
                let base = Int32(verts.count)
                for k in 0..<pointsPerStrand {
                    let t = Float(k) / Float(pointsPerStrand - 1)
                    let a = (t - 0.5) * arc
                    // arc along a great circle through `dir`, plus a 3D curl, kept near the sphere
                    var p = dir * cosf(a) + tangent * sinf(a)
                    p += binormal * (sinf(t * Float.pi * curl + phase) * 0.12)
                    let radial = R * (1 + sinf(t * Float.pi * 2 + phase) * 0.05)
                    let pp = simd_normalize(p) * radial
                    verts.append(SCNVector3(pp.x, pp.y, pp.z))
                    if k < pointsPerStrand - 1 {
                        indices.append(base + Int32(k))
                        indices.append(base + Int32(k + 1))
                    }
                }
            }
            let src = SCNGeometrySource(vertices: verts)
            let elem = SCNGeometryElement(indices: indices, primitiveType: .line)
            return SCNGeometry(sources: [src], elements: [elem])
        }

        func update(level: Float, accent: UIColor) {
            let l = CGFloat(max(0, min(1, level)))
            tick += 0.05
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.12

            // Tint the weave + halo to the accent; core stays hot/near-white but takes a
            // little of the accent so blue-listening vs amber-speaking reads through.
            filamentMat.emission.contents = accent
            filamentMat.emission.intensity = 0.9 + l * 1.8
            glowMat.emission.contents = accent
            glowMat.emission.intensity = 0.35 + l * 0.9
            halo.particleColor = accent
            halo.birthRate = CGFloat(280 + l * 700)

            let hot = blend(UIColor(red: 1, green: 0.96, blue: 0.9, alpha: 1), accent, 0.25 + l * 0.25)
            coreMat.emission.contents = hot
            coreMat.emission.intensity = 1.4 + l * 1.8
            let s = 1.0 + l * 0.25
            core.scale = SCNVector3(Float(s), Float(s), Float(s))
            SCNTransaction.commit()
        }

        private func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            let u = max(0, min(1, t))
            return UIColor(red: ar + (br - ar) * u, green: ag + (bg - ag) * u,
                           blue: ab + (bb - ab) * u, alpha: 1)
        }
    }
}

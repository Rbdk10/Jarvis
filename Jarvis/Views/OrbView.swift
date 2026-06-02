import SwiftUI
import SceneKit

/// A soft luminous core wrapped in a cage of fine filament "strands" that reach from
/// just outside the core outward, like hair or fibre-optic threads. The strands are
/// still at rest and only stir — bending, lengthening and brightening — as `level`
/// (0...1) rises, so the orb moves *only* while Jarvis is speaking.
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
        private let breath = SCNNode()
        private let core = SCNNode()
        private let glow = SCNNode()
        private let cage = SCNNode()
        private let coreMaterial = SCNMaterial()
        private let glowMaterial = SCNMaterial()

        // One entry per filament strand.
        private struct Strand {
            let strand: SCNNode          // the visible thread; pivoted at its inner base
            let material: SCNMaterial
            let phase: Float             // de-syncs the per-strand sway
            let lengthJitter: Float      // slight natural variation in resting length
        }
        private var strands: [Strand] = []
        private var tick: Float = 0

        // Blue-white palette. Strands lerp between these so the cage reads as light, not plastic.
        private let deepBlue  = UIColor(red: 0.32, green: 0.62, blue: 1.00, alpha: 1)
        private let paleWhite = UIColor(red: 0.86, green: 0.94, blue: 1.00, alpha: 1)

        private let baseRadius: CGFloat = 0.92   // strands start just outside the core
        private let strandLen: CGFloat = 1.15
        private let strandCount = 150

        func buildScene() -> SCNScene {
            let scene = SCNScene()

            let cam = SCNNode()
            cam.camera = SCNCamera()
            cam.position = SCNVector3(0, 0, 6)
            scene.rootNode.addChildNode(cam)

            // Soft, matte-reading luminous core: a constant-lit sphere with a gentle
            // emission. No specular highlight, so it looks like light rather than plastic.
            let coreGeo = SCNSphere(radius: 0.82)
            coreGeo.segmentCount = 96
            coreMaterial.lightingModel = .constant
            coreMaterial.diffuse.contents = UIColor.black
            coreMaterial.emission.contents = paleWhite
            coreMaterial.emission.intensity = 0.9
            coreGeo.firstMaterial = coreMaterial
            core.geometry = coreGeo

            // A faint outer glow halo (additive, no hard edge) for atmosphere.
            let glowGeo = SCNSphere(radius: 1.25)
            glowGeo.segmentCount = 64
            glowMaterial.lightingModel = .constant
            glowMaterial.diffuse.contents = UIColor.clear
            glowMaterial.emission.contents = deepBlue
            glowMaterial.emission.intensity = 0.22
            glowMaterial.transparency = 0.30
            glowMaterial.fresnelExponent = 2.5
            glowMaterial.blendMode = .add
            glowMaterial.isDoubleSided = true
            glowMaterial.writesToDepthBuffer = false
            glowGeo.firstMaterial = glowMaterial
            glow.geometry = glowGeo

            buildStrands()

            breath.addChildNode(core)
            breath.addChildNode(glow)
            breath.addChildNode(cage)
            scene.rootNode.addChildNode(breath)

            // The soft core is allowed a slow, gentle breath at rest — that part Antoonie
            // liked. The strands themselves stay still until `level` drives them.
            breath.runAction(.repeatForever(.sequence([
                .scale(to: 1.03, duration: 2.4),
                .scale(to: 1.0, duration: 2.4)
            ])))

            return scene
        }

        /// Distribute strand directions evenly over a sphere (Fibonacci) and build each
        /// as a thin cylinder pivoted at its inner base so it grows/bends from the core.
        private func buildStrands() {
            let golden = Float.pi * (3 - sqrtf(5))
            for i in 0..<strandCount {
                let y = 1 - (Float(i) / Float(strandCount - 1)) * 2      // 1 … -1
                let r = sqrtf(max(0, 1 - y * y))
                let theta = golden * Float(i)
                let dir = SCNVector3(r * cosf(theta), y, r * sinf(theta))

                // Holder points its +Y axis along `dir`; it stays fixed.
                let holder = SCNNode()
                orient(holder, toDirection: dir)

                let jitter = Float((i % 7)) / 7.0 * 0.35                  // 0 … 0.35
                let len = strandLen * CGFloat(1 + jitter * 0.4)
                let geo = SCNCylinder(radius: 0.011, height: len)
                geo.radialSegmentCount = 6
                let mat = SCNMaterial()
                mat.lightingModel = .constant
                mat.diffuse.contents = UIColor.black
                let tint = lerp(deepBlue, paleWhite, t: CGFloat(jitter / 0.35))
                mat.emission.contents = tint
                mat.emission.intensity = 0.5
                mat.blendMode = .add
                mat.writesToDepthBuffer = false
                geo.firstMaterial = mat

                let strand = SCNNode()
                strand.geometry = geo
                // Pivot at the inner end so scale.y lengthens outward and euler bends from base.
                strand.pivot = SCNMatrix4MakeTranslation(0, Float(-len / 2), 0)
                strand.position = SCNVector3(0, Float(baseRadius), 0)
                strand.scale = SCNVector3(1, 0.72, 1)                    // resting: short

                holder.addChildNode(strand)
                cage.addChildNode(holder)
                strands.append(Strand(strand: strand, material: mat,
                                      phase: theta, lengthJitter: jitter))
            }
        }

        func update(level: Float, accent: UIColor) {
            let l = max(0, min(1, level))
            tick += 0.05

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.10

            // Core brightens a touch when speaking.
            coreMaterial.emission.intensity = CGFloat(0.9 + l * 0.7)
            glowMaterial.emission.intensity = CGFloat(0.22 + l * 0.5)

            // Strands: bend (sway), lengthen and brighten with the voice level.
            for s in strands {
                let p = s.phase
                let swayX = l * 0.34 * sinf(tick * 2.0 + p)
                let swayZ = l * 0.34 * cosf(tick * 2.3 + p * 1.3)
                s.strand.eulerAngles = SCNVector3(swayX, 0, swayZ)
                let lenScale = 0.72 + l * (0.9 + s.lengthJitter)
                s.strand.scale = SCNVector3(1, lenScale, 1)
                s.material.emission.intensity = CGFloat(0.45 + l * 2.1)
            }
            SCNTransaction.commit()
        }

        // MARK: helpers

        /// Rotate `node` so its local +Y axis aligns with `dir` (assumed ~unit length).
        private func orient(_ node: SCNNode, toDirection dir: SCNVector3) {
            let up = SCNVector3(0, 1, 0)
            let d = normalize(dir)
            let dot = up.x * d.x + up.y * d.y + up.z * d.z
            if dot > 0.9999 { return }                       // already aligned
            if dot < -0.9999 {                               // opposite: flip around X
                node.rotation = SCNVector4(1, 0, 0, Float.pi)
                return
            }
            let axis = normalize(SCNVector3(up.y * d.z - up.z * d.y,
                                            up.z * d.x - up.x * d.z,
                                            up.x * d.y - up.y * d.x))
            node.rotation = SCNVector4(axis.x, axis.y, axis.z, acosf(dot))
        }

        private func normalize(_ v: SCNVector3) -> SCNVector3 {
            let m = sqrtf(v.x * v.x + v.y * v.y + v.z * v.z)
            guard m > 0 else { return SCNVector3(0, 1, 0) }
            return SCNVector3(v.x / m, v.y / m, v.z / m)
        }

        private func lerp(_ a: UIColor, _ b: UIColor, t: CGFloat) -> UIColor {
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            let u = max(0, min(1, t))
            return UIColor(red: ar + (br - ar) * u,
                           green: ag + (bg - ag) * u,
                           blue: ab + (bb - ab) * u,
                           alpha: aa + (ba - aa) * u)
        }
    }
}

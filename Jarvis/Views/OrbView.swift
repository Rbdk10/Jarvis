import SwiftUI
import SceneKit

/// A 3D "energy bubble": a glowing core inside a translucent shell with an additive
/// particle halo. Its scale and glow track `level` (0...1) so it pulses with the voice.
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
        private let shell = SCNNode()
        private let coreMaterial = SCNMaterial()
        private let shellMaterial = SCNMaterial()
        private let halo = SCNParticleSystem()

        func buildScene() -> SCNScene {
            let scene = SCNScene()

            let cam = SCNNode()
            cam.camera = SCNCamera()
            cam.position = SCNVector3(0, 0, 6)
            scene.rootNode.addChildNode(cam)

            // Glowing core
            let coreGeo = SCNSphere(radius: 1.0)
            coreGeo.segmentCount = 96
            coreMaterial.lightingModel = .constant
            coreMaterial.diffuse.contents = UIColor.black
            coreMaterial.emission.contents = UIColor.cyan
            coreGeo.firstMaterial = coreMaterial
            core.geometry = coreGeo

            // Translucent bubble shell with a fresnel rim
            let shellGeo = SCNSphere(radius: 1.6)
            shellGeo.segmentCount = 96
            shellMaterial.lightingModel = .constant
            shellMaterial.diffuse.contents = UIColor.clear
            shellMaterial.emission.contents = UIColor.cyan
            shellMaterial.emission.intensity = 0.25
            shellMaterial.transparency = 0.18
            shellMaterial.fresnelExponent = 2.0
            shellMaterial.isDoubleSided = true
            shellGeo.firstMaterial = shellMaterial
            shell.geometry = shellGeo

            // Additive particle halo
            halo.birthRate = 500
            halo.particleLifeSpan = 2.5
            halo.particleSize = 0.02
            halo.particleColor = .cyan
            halo.emitterShape = SCNSphere(radius: 1.5)
            halo.birthLocation = .surface
            halo.particleVelocity = 0.04
            halo.isAffectedByGravity = false
            halo.blendMode = .additive
            shell.addParticleSystem(halo)

            breath.addChildNode(core)
            breath.addChildNode(shell)
            scene.rootNode.addChildNode(breath)

            // Idle "breath" + slow counter-rotation
            breath.runAction(.repeatForever(.sequence([
                .scale(to: 1.04, duration: 2.0),
                .scale(to: 1.0, duration: 2.0)
            ])))
            shell.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 30)))
            core.runAction(.repeatForever(.rotateBy(x: 0, y: -.pi * 2, z: 0, duration: 45)))

            return scene
        }

        func update(level: Float, accent: UIColor) {
            let l = CGFloat(max(0, min(1, level)))
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.10
            let coreScale = 1.0 + l * 0.35
            core.scale = SCNVector3(coreScale, coreScale, coreScale)
            let shellScale = 1.0 + l * 0.20
            shell.scale = SCNVector3(shellScale, shellScale, shellScale)
            coreMaterial.emission.contents = accent
            coreMaterial.emission.intensity = 0.8 + l * 1.6
            shellMaterial.emission.contents = accent
            halo.particleColor = accent
            SCNTransaction.commit()
        }
    }
}

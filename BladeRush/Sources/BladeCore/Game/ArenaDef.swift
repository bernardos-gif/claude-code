// Arena theme presets (Data/arenas.json): floor, architecture, props, weather, sky,
// fog, lights and color grading. The ArenaBuilder turns a preset into meshes, instance
// placements, colliders and lights.
import Foundation

public struct ArenaLight: Codable, Equatable {
    public var position: Vec3 = Vec3(0, 3, 0)
    public var color = "#ff9a4a"
    public var intensity: Float = 20
    public var radius: Float = 8
    public var flicker: Float = 0.3

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ArenaLight()
        position = try c.v(.position, d.position); color = try c.v(.color, d.color); intensity = try c.v(.intensity, d.intensity)
        radius = try c.v(.radius, d.radius); flicker = try c.v(.flicker, d.flicker)
    }
}

public struct PropPlacement: Codable, Equatable {
    public var kind = "pillar"
    public var count = 8
    public var ring: Float = 18          // placement radius (rect arenas: distance from edge)
    public var jitter: Float = 1.5
    public var scale: Float = 1
    public var scaleJitter: Float = 0.15
    public var angleOffset: Float = 0
    public var seed = 1
    public var color = ""
    public var material = ""
    public var light = false
    public var broken: Float = 0.3       // chance a piece is broken / ruined
    public var arc: Float = 360          // degrees of the ring to fill

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PropPlacement()
        kind = try c.v(.kind, d.kind); count = try c.v(.count, d.count); ring = try c.v(.ring, d.ring); jitter = try c.v(.jitter, d.jitter)
        scale = try c.v(.scale, d.scale); scaleJitter = try c.v(.scaleJitter, d.scaleJitter); angleOffset = try c.v(.angleOffset, d.angleOffset)
        seed = try c.v(.seed, d.seed); color = try c.v(.color, d.color); material = try c.v(.material, d.material)
        light = try c.v(.light, d.light); broken = try c.v(.broken, d.broken); arc = try c.v(.arc, d.arc)
    }
}

public struct ColorGrading: Codable, Equatable {
    public var exposure: Float = 1
    public var contrast: Float = 1.08
    public var saturation: Float = 1.0
    public var tint = "#ffffff"
    public var shadows = "#1a1c2a"
    public var highlights = "#fff2dc"
    public var splitStrength: Float = 0.25
    public var vignette: Float = 0.35
    public var bloom: Float = 0.9

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ColorGrading()
        exposure = try c.v(.exposure, d.exposure); contrast = try c.v(.contrast, d.contrast); saturation = try c.v(.saturation, d.saturation)
        tint = try c.v(.tint, d.tint); shadows = try c.v(.shadows, d.shadows); highlights = try c.v(.highlights, d.highlights)
        splitStrength = try c.v(.splitStrength, d.splitStrength); vignette = try c.v(.vignette, d.vignette); bloom = try c.v(.bloom, d.bloom)
    }
}

/// Lighting override used for phase transitions ("red", "dark", "storm"...).
public struct LightingShift: Codable, Equatable {
    public var sunColor = ""
    public var sunIntensity: Float?
    public var fogColor = ""
    public var fogDensity: Float?
    public var tint = ""
    public var sky = ""
    public var rimColor = ""

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sunColor = try c.v(.sunColor, ""); sunIntensity = try c.decodeIfPresent(Float.self, forKey: .sunIntensity)
        fogColor = try c.v(.fogColor, ""); fogDensity = try c.decodeIfPresent(Float.self, forKey: .fogDensity)
        tint = try c.v(.tint, ""); sky = try c.v(.sky, ""); rimColor = try c.v(.rimColor, "")
    }
}

public struct ArenaDef: Codable, Equatable {
    public var id = ""
    public var name = ""
    public var shape = "circle"          // circle, rect
    public var radius: Float = 15
    public var size: Vec2 = Vec2(30, 22)
    public var floor = "flagstone"       // flagstone, dirt, planks, snow, ice, marble, obsidian, sand, moss, grate, tatami, rock, bone, water
    public var floorColor = "#5a5550"
    public var floorColor2 = "#3a3632"
    public var floorRoughness: Float = 0.8
    public var wet: Float = 0            // puddles / polish -> screen-space reflections
    public var sky = "dusk"              // dusk, storm, eclipse, aurora, bloodmoon, underground, night, overcast, dawn, void
    public var sunDir: Vec3 = Vec3(-0.4, 0.35, -0.6)
    public var sunColor = "#ffb070"
    public var sunIntensity: Float = 3.2
    public var ambient: Float = 0.45
    public var ambientColor = ""
    public var fogColor = "#6a5a60"
    public var fogDensity: Float = 0.018
    public var fogHeight: Float = 6
    public var fogScatter: Float = 0.6
    public var rimColor = "#ffcf9a"
    public var rimIntensity: Float = 0.6
    public var grading = ColorGrading()
    public var weather = "none"          // none, rain, snow, ash, embers, leaves, dust, sparks, spores, petals
    public var weatherIntensity: Float = 1
    public var lightning = false
    public var props: [PropPlacement] = []
    public var lights: [ArenaLight] = []
    public var backdrop = "cliffs"       // cliffs, mountains, walls, sea, cave, void, forest, city, forge, spires
    public var backdropColor = "#3a3a44"
    public var shifts: [String: LightingShift] = [:]
    public var music = MusicStyle()
    public var footstep = "stone"        // stone, dirt, wood, snow, water, metal, sand

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ArenaDef()
        id = try c.v(.id, d.id); name = try c.v(.name, d.name); shape = try c.v(.shape, d.shape); radius = try c.v(.radius, d.radius)
        size = try c.v(.size, d.size); floor = try c.v(.floor, d.floor); floorColor = try c.v(.floorColor, d.floorColor)
        floorColor2 = try c.v(.floorColor2, d.floorColor2); floorRoughness = try c.v(.floorRoughness, d.floorRoughness)
        wet = try c.v(.wet, d.wet); sky = try c.v(.sky, d.sky); sunDir = try c.v(.sunDir, d.sunDir); sunColor = try c.v(.sunColor, d.sunColor)
        sunIntensity = try c.v(.sunIntensity, d.sunIntensity); ambient = try c.v(.ambient, d.ambient); ambientColor = try c.v(.ambientColor, d.ambientColor)
        fogColor = try c.v(.fogColor, d.fogColor); fogDensity = try c.v(.fogDensity, d.fogDensity); fogHeight = try c.v(.fogHeight, d.fogHeight)
        fogScatter = try c.v(.fogScatter, d.fogScatter); rimColor = try c.v(.rimColor, d.rimColor); rimIntensity = try c.v(.rimIntensity, d.rimIntensity)
        grading = try c.v(.grading, d.grading); weather = try c.v(.weather, d.weather); weatherIntensity = try c.v(.weatherIntensity, d.weatherIntensity)
        lightning = try c.v(.lightning, d.lightning); props = try c.v(.props, d.props); lights = try c.v(.lights, d.lights)
        backdrop = try c.v(.backdrop, d.backdrop); backdropColor = try c.v(.backdropColor, d.backdropColor); shifts = try c.v(.shifts, d.shifts)
        music = try c.v(.music, d.music); footstep = try c.v(.footstep, d.footstep)
    }

    /// Distance from the arena center to the boundary along a direction (for movement clamps).
    public func clamp(_ p: Vec3, margin: Float) -> Vec3 {
        if shape == "rect" {
            let hx = size.x * 0.5 - margin, hz = size.y * 0.5 - margin
            return Vec3(clampf(p.x, -hx, hx), p.y, clampf(p.z, -hz, hz))
        }
        let r = radius - margin
        let d = vlength2(p.xz)
        if d <= r { return p }
        let k = r / d
        return Vec3(p.x * k, p.y, p.z * k)
    }

    public var boundingRadius: Float { shape == "rect" ? vlength2(size) * 0.5 : radius }
}

public struct MusicStyle: Codable, Equatable {
    public var tempo: Float = 120
    public var root: Int = 45            // MIDI note of the tonic (A2)
    public var mode = "aeolian"          // aeolian, phrygian, harmonicMinor, dorian, locrian
    public var drums = "taiko"           // taiko, march, tribal, industrial, sparse, war
    public var pad = "strings"           // strings, choir, organ, glass
    public var lead = "pluck"            // pluck, bell, shakuhachi, brass, none
    public var intensity: Float = 1

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MusicStyle()
        tempo = try c.v(.tempo, d.tempo); root = try c.v(.root, d.root); mode = try c.v(.mode, d.mode)
        drums = try c.v(.drums, d.drums); pad = try c.v(.pad, d.pad); lead = try c.v(.lead, d.lead); intensity = try c.v(.intensity, d.intensity)
    }
}

public struct ArenasFile: Codable {
    public var arenas: [ArenaDef] = []
}

// Звуковые эффекты для ролика — синтезированы, без чужих сэмплов (никаких вопросов с правами).
//   swift promo/sfx.swift promo/public/sfx
import Foundation

let rate = 44_100.0
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/// Детерминированный шум.
var seed: UInt64 = 0x9E3779B97F4A7C15
func noise() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(Int64(bitPattern: seed >> 11) % 1_000_000) / 1_000_000 * 2 - 1
}

typealias Stereo = (l: [Double], r: [Double])

func render(_ seconds: Double, _ f: (Double, Int) -> (Double, Double)) -> Stereo {
    let n = Int(seconds * rate)
    var l = [Double](repeating: 0, count: n), r = l
    for i in 0..<n { let s = f(Double(i) / rate, i); l[i] = s.0; r[i] = s.1 }
    return (l, r)
}

/// Простая «комната»: несколько затухающих задержек, чтобы звук не был сухим.
func reverb(_ s: Stereo, mix: Double = 0.25) -> Stereo {
    let taps: [(Double, Double)] = [(0.029, 0.5), (0.043, 0.42), (0.061, 0.33), (0.083, 0.25), (0.117, 0.18), (0.163, 0.12)]
    var l = s.l, r = s.r
    let tail = Int(0.4 * rate)
    l += [Double](repeating: 0, count: tail); r += [Double](repeating: 0, count: tail)
    for (k, (d, g)) in taps.enumerated() {
        let off = Int(d * rate)
        for i in 0..<s.l.count {
            let (a, b) = k % 2 == 0 ? (s.l[i], s.r[i]) : (s.r[i], s.l[i])
            l[i + off] += a * g * mix
            r[i + off] += b * g * mix
        }
    }
    return (l, r)
}

func write(_ name: String, _ s: Stereo, peak: Double = 0.7) {
    let m = max(s.l.map(abs).max() ?? 1, s.r.map(abs).max() ?? 1, 1e-9)
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let n = s.l.count
    data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + n * 4)); data.append(contentsOf: "WAVEfmt ".utf8)
    u32(16); u16(1); u16(2); u32(UInt32(rate)); u32(UInt32(rate) * 4); u16(4); u16(16)
    data.append(contentsOf: "data".utf8); u32(UInt32(n * 4))
    for i in 0..<n {
        for v in [s.l[i], s.r[i]] { u16(UInt16(bitPattern: Int16(max(-1, min(1, v / m * peak)) * 32767))) }
    }
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).wav"))
}

func env(_ t: Double, attack: Double, decay: Double) -> Double { t < attack ? t / attack : exp(-(t - attack) / decay) }

// Вжух: шум через плавающий фильтр, панорама слева направо.
func whoosh(_ dur: Double, from: Double = 300, peak: Double = 5500) -> Stereo {
    var lp = 0.0, lp2 = 0.0
    return reverb(render(dur) { t, _ in
        let p = t / dur
        let cutoff = from + (peak - from) * sin(.pi * p)
        let a = 1 - exp(-2 * .pi * cutoff / rate)
        lp += a * (noise() - lp); lp2 += a * (lp - lp2)
        let amp = pow(sin(.pi * p), 1.6)
        let pan = p
        return (lp2 * amp * (1 - pan * 0.7), lp2 * amp * (0.3 + pan * 0.7))
    }, mix: 0.3)
}

// Щелчок переключателя.
func click(_ freq: Double = 2400) -> Stereo {
    render(0.06) { t, _ in
        let s = sin(2 * .pi * freq * t) * exp(-t / 0.008) + noise() * exp(-t / 0.002) * 0.6
        return (s, s)
    }
}

// «Поп» — плашки и логотип.
func pop(_ f0: Double = 520, _ f1: Double = 1100) -> Stereo {
    var ph = 0.0
    return reverb(render(0.18) { t, _ in
        ph += 2 * .pi * (f0 + (f1 - f0) * min(1, t / 0.05)) / rate
        let s = sin(ph) * env(t, attack: 0.002, decay: 0.04)
        return (s, s)
    }, mix: 0.2)
}

// Ошибка — низкое «бзз» с тремоло.
func buzz() -> Stereo {
    render(0.32) { t, _ in
        let sq = (sin(2 * .pi * 98 * t) > 0 ? 1.0 : -1.0) * 0.5 + sin(2 * .pi * 147 * t) * 0.5
        let s = sq * env(t, attack: 0.004, decay: 0.12) * (0.75 + 0.25 * sin(2 * .pi * 28 * t))
        return (s * 0.9, s)
    }
}

// Цифровой сбой.
func glitch() -> Stereo {
    var hold = 0.0
    return render(0.16) { t, i in
        if i % 220 == 0 { hold = noise() }
        let crushed = (noise() * 0.5 + hold * 0.5)
        let s = (Double(Int(crushed * 6)) / 6) * env(t, attack: 0.001, decay: 0.06) + sin(2 * .pi * (900 + 1400 * hold) * t) * 0.3 * env(t, attack: 0.001, decay: 0.05)
        return (s, -s * 0.8)
    }
}

// Удар: падающий по высоте низ + щелчок + хвост.
func impact() -> Stereo {
    var ph = 0.0, lp = 0.0
    return reverb(render(1.2) { t, _ in
        ph += 2 * .pi * (40 + 110 * exp(-t / 0.08)) / rate
        lp += 0.08 * (noise() - lp)
        let s = sin(ph) * env(t, attack: 0.003, decay: 0.35) + lp * 2.2 * env(t, attack: 0.001, decay: 0.05)
        return (s, s)
    }, mix: 0.45)
}

// Искры: быстрые высокие ноты пентатоники, разлетаются по стерео.
func shimmer(_ dur: Double = 1.6) -> Stereo {
    let notes = [1046.5, 1318.5, 1568.0, 2093.0, 2637.0, 1760.0, 2349.3, 3136.0, 1975.5, 2793.8]
    return reverb(render(dur) { t, _ in
        var l = 0.0, r = 0.0
        for (k, f) in notes.enumerated() {
            let start = Double(k) * 0.085
            guard t >= start else { continue }
            let u = t - start
            let v = (sin(2 * .pi * f * u) + 0.3 * sin(2 * .pi * f * 2.01 * u)) * env(u, attack: 0.003, decay: 0.22) * 0.35
            let pan = Double(k % 5) / 4
            l += v * (1 - pan); r += v * pan
        }
        return (l, r)
    }, mix: 0.5)
}

// Подъём перед финалом.
func riser(_ dur: Double = 1.1) -> Stereo {
    var ph = 0.0, lp = 0.0
    return reverb(render(dur) { t, _ in
        let p = t / dur
        ph += 2 * .pi * (180 + 900 * p * p) / rate
        lp += (0.02 + 0.3 * p) * (noise() - lp)
        let s = (sin(ph) * 0.5 + lp * 0.8) * pow(p, 2) * (p < 0.97 ? 1 : (1 - p) / 0.03)
        return (s, s)
    }, mix: 0.35)
}

// Звон «готово».
func chime(_ base: Double = 1318.5) -> Stereo {
    reverb(render(1.4) { t, _ in
        let s = (sin(2 * .pi * base * t) + 0.6 * sin(2 * .pi * base * 1.5 * t) + 0.25 * sin(2 * .pi * base * 2 * t))
            * env(t, attack: 0.004, decay: 0.45)
        return (s, s * 0.92)
    }, mix: 0.5)
}

// Мягкий низкий «тук» — панель встала на место.
func thud() -> Stereo {
    render(0.25) { t, _ in
        let s = sin(2 * .pi * (70 + 40 * exp(-t / 0.03)) * t) * env(t, attack: 0.002, decay: 0.07)
        return (s, s)
    }
}

write("whoosh", whoosh(0.5))
write("whoosh-long", whoosh(0.8, from: 200, peak: 7000))
write("click", click(), peak: 0.6)
write("click-low", click(1500), peak: 0.6)
write("pop", pop(), peak: 0.6)
write("buzz", buzz(), peak: 0.6)
write("glitch", glitch(), peak: 0.55)
write("impact", impact(), peak: 0.9)
write("shimmer", shimmer(), peak: 0.6)
write("riser", riser(), peak: 0.6)
write("chime", chime(), peak: 0.7)
write("thud", thud(), peak: 0.8)
print("ok")

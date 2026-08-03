//
//  Theme.swift
//  Sub4
//
//  Colours mirror the swatches in the HTML plan so the two read as one system.
//
//  TWO SCHEMES, ONE NAME
//  ---------------------
//  Every colour below resolves per trait collection through `dyn(dark:light:)`.
//  Nothing at a call site changes: `Color.dim` is still `Color.dim`, and the
//  system hands it the right value for whichever scheme is active. The
//  alternative — an observable palette threaded through every view — would have
//  touched every file in the project and given SwiftUI two sources of truth
//  about appearance.
//
//  THE LIGHT SCHEME IS NOT AN INVERSION
//  ------------------------------------
//  It is its own palette, and it had to be: three of the dark theme's decisions
//  do not survive the move to a white surface, and the palette validator caught
//  all three before a line was written.
//
//    1. THE COMMUTE. On dark it is bike cyan at 55% — a tint TOWARDS the
//       background, which keeps its chroma and reads as "bike, quieter". On
//       white the same move strips chroma and separation together: lighter
//       scored ΔE 12.4 / chroma 0.087 / contrast 2.39, three failures at once,
//       and darker failed the chroma floor. It needs its own hue on light, and
//       the family resemblance to the bike is simply lost. There is no better
//       tint — Swift Charts has no pattern fill for BarMark, which is how this
//       is normally solved.
//
//    2. THE ZONES. Blue · green · amber · orange · red, darkened enough to
//       clear white, converge: best of three attempts put an adjacent pair at
//       ΔE 9.0, and the normal-vision floor of 15 is the one check secondary
//       encoding does not excuse. Zones are ordinal, so light uses a single-hue
//       sequential ramp — monotone lightness, gaps ≥ 0.06, light end 2.29:1
//       against the card. Re-stepped darker in patch 100 when the card itself
//       darkened; a pale ramp end and a tinted surface compete for the same
//       lightness.
//       THE COST IS MEANING: on dark, Z5 is red because red says hard. On light
//       the ramp says "more", not "harder". Every bar carries its full name on
//       both schemes, so identity never rests on the hue alone.
//
//    3. THE SERIES HUES. Re-stepped, not reused. Validated adjacent-pairs at
//       ΔE 18.6 normal / 11.8 deutan with every mark ≥ 3:1 against the surface —
//       the same standard the dark set was signed off under. Under --pairs all
//       the worst is commute↔swim at 10.9; they are never adjacent in the stack
//       and every series is directly labelled, the same caveat the dark palette
//       already carries.
//
//  The light scheme is "Clinical": hairline rules, no radius change, nothing
//  decorative. Chosen from four mockups because it is closest in spirit to the
//  dark build, which is also mostly rules and figures. Its one departure from
//  the mockup is the card surface — see `Color.card`.
//

import SwiftUI

/// One colour, two schemes. `Color(uiColor:)` with a dynamic provider is the
/// only form that resolves inside Swift Charts, which renders marks outside the
/// SwiftUI environment a `@Environment(\.colorScheme)` read would see.
func dyn(dark: UInt32, light: UInt32) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
}

private func ui(_ hex: UInt32) -> UIColor {
    UIColor(red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >>  8) & 0xFF) / 255,
            blue:  CGFloat( hex        & 0xFF) / 255,
            alpha: 1)
}

extension Color {

    // MARK: Surfaces and ink

    /// THE CARD IS DARKER THAN THE PAGE, which is the reverse of the usual iOS
    /// arrangement and deliberate. Patch 99 shipped both at #FFFFFF with only
    /// the hairline separating them, and a card you can only find by its border
    /// is not a card. #F1F3F7 gives 1.11:1 against the page — enough to see the
    /// edge without turning the page into a grid of grey boxes.
    ///
    /// It is also the reason the zone ramp's light end moved. A darker surface
    /// eats the pale end of a sequential ramp: #88ADD4 measured 2.11:1 here
    /// against a 2.0 floor, which is 0.11 of headroom and one design tweak away
    /// from failing. The whole ramp steps down with the card.
    static let bg   = dyn(dark: 0x0F1115, light: 0xFFFFFF)
    static let card = dyn(dark: 0x181B22, light: 0xF1F3F7)
    /// Stepped with the card — #E3E6EC on #F1F3F7 is 1.13:1 and disappears.
    static let line = dyn(dark: 0x262B35, light: 0xD6DAE3)
    static let dim  = dyn(dark: 0x8B93A1, light: 0x646C7C)

    /// PRIMARY TEXT. Was a bare `.white` at fifty call sites, which is exactly
    /// as invisible on a white card as it sounds. One name now, so the next
    /// scheme is a two-hex change rather than another sweep.
    static let ink  = dyn(dark: 0xFFFFFF, light: 0x0E1116)

    /// The brand orange. Darkened on light — #FB923C is 1.9:1 against white and
    /// would have failed every mark on the page.
    ///
    /// ON CHARTS IT IS THE WEEKLY-LOAD LINE AND THE PLAN-START RULE, AND THAT
    /// IS ITS LIMIT. It is not a direction, a state or a verdict. It used to be
    /// "up" on the volume tiles against `slowerColor` for "down"; patch 142 took
    /// that away, because a brand colour standing in for "good" is how the warm
    /// band ended up with four tenants. See `bandTint`.
    static let accent4 = dyn(dark: 0xFB923C, light: 0xC2410C)

    // WHY THE dataviz VALIDATOR FAILS THIS PALETTE'S DARK STEPS
    // ---------------------------------------------------------
    // Anyone running `validate_palette.js --mode dark` over these colours gets
    // "Lightness band — outside band" on most of them: #619EF5 sits at L 0.697,
    // #F59E4D at 0.772, #59D499 at 0.785, against a band of 0.43–0.77.
    //
    // It is not a regression and it is not worth chasing. That band is tuned for
    // series drawn on a LIGHT surface, where a mark has to be dark enough to
    // read against white. These are drawn on #181B22, where the same argument
    // runs the other way and a mark inside the band would be too dark to see.
    // Every separation and contrast check passes; only the band does not.
    //
    // Written down so a future run of the validator is not read as damage. What
    // IS worth acting on from that tool: the CVD checks, the normal-vision floor
    // of 15, and contrast — all three have caught real faults in this file.



    /// The sixth volume band: walks, the kayak, the row — everything recorded
    /// that the plan has no discipline for.
    ///
    /// WHY NOT GREY, WHICH IS WHAT A RESIDUAL USUALLY GETS
    /// ---------------------------------------------------
    /// Because it was measured and it fails. `dim` used as a band comes out at
    /// ΔE 11.1 against the commute purple on light and 13.0 against the commute
    /// teal on dark — both under the normal-vision floor of 15, which is the one
    /// check a legend cannot excuse: it means a reader with full colour vision
    /// cannot separate the two fills where they meet. Taupe fails the same pair
    /// at 14.1. Gold is the nearest hue that clears every check the existing
    /// five already clear, on both surfaces, without introducing a new worst
    /// pair — the worst adjacent separation stays 19.7 (deutan, dark) and 11.8
    /// (deutan, light), both set by pairs that predate this band.
    ///
    /// It sits at the TOP of the stack, where its only neighbour is the commute
    /// — which is the pairing those two numbers were taken from.
    static let residual = dyn(dark: 0xD9C24A, light: 0x7A6300)

    // MARK: The fitness curve's own hues
    //
    // ONE definition, because three screens draw the same three series — the
    // Today strip, the Progress card and the expanded panel — and a swatch that
    // does not match its own line is worse than no swatch at all.
    static let ctlTint = dyn(dark: 0x59D499, light: 0x0F7B5A)
    static let atlTint = dyn(dark: 0xFFB02E, light: 0xB07D00)

    /// TSB is the AREA between the two lines, not a line. Its swatch is the
    /// area's own fill rather than a hue borrowed from a series it is not part
    /// of — brightened, because 6% white is invisible at 10 points.
    static var tsbFill: Color { Color.ink.opacity(0.22) }

    // MARK: Faster / slower, and the second shoe threshold

    /// The diverging pair for deviation, plus the middle the pair never had.
    ///
    /// FASTER WAS CYAN UNTIL PATCH 102 and had to move. The split table now
    /// draws a third state — inside the target band — and "on target" has been
    /// green since the verdict card was written. Green against that cyan is the
    /// worst pair in the project: ΔE 10.9 on dark, 12.1 on light, both under the
    /// 15 floor. Blue clears it on both, all-pairs:
    ///
    ///     dark  #619EF5 · #59D499 · #F59E4D   worst ΔE 21.3 normal · 8.9 deutan
    ///     light #2456C7 · #0F7B5A · #B45309   worst ΔE 21.7 normal · 8.6 protan
    ///
    /// Moving faster rather than moving on-target was the right way round: green
    /// for "held it" is the older convention here, and the interval table has
    /// been drawing it that way all along.
    static let fasterColor = dyn(dark: 0x619EF5, light: 0x2456C7)
    static let slowerColor = dyn(dark: 0xF59E4D, light: 0xB45309)

    /// Inside the band. Named for the meaning rather than borrowed from the run
    /// tint it happens to equal, because the two can move apart.
    static let onTargetColor = dyn(dark: 0x59D499, light: 0x0F7B5A)

    /// The shading behind a flagged span, and the threshold rule that names it.
    /// Currently: high-monotony weeks on the fitness chart, and the Foster 2.0
    /// line on Load pattern.
    ///
    /// WHY THIS TOKEN HAD TO EXIST — patch 142
    /// ----------------------------------------
    /// All of this used to be `slowerColor`, which put FOUR roles in the warm
    /// band on dark: brand (`accent4` #FB923C), a data series (`atlTint`
    /// #FFB02E), a status (`slowerColor` #F59E4D) and a state (`spentColor`
    /// #E5484D). The first three measure ΔE 2.7, 5.7 and 7.5 against each other
    /// at normal vision — a floor of 15 — and the Load pattern legend printed
    /// an `accent4` line two rows above a `slowerColor` rule, at ΔE 2.7. The
    /// same orange, three meanings, in one legend.
    ///
    /// THERE IS NO WARM HEX THAT FIXES IT. Every RGB in the warm family was
    /// enumerated against all five neighbours on the #181B22 card: zero clear
    /// the floor. accent4 and atlTint fence it above, spentColor below, and the
    /// gap between is roughly ΔE 17 wide — not enough for a fourth colour. The
    /// nearest misses were #E8703A (8.7 from spent) and #FF7A45 (5.5 from
    /// accent4). A palette can be over-subscribed, and this one was.
    ///
    /// So a role left. The band is the one that never needed a hue: it marks
    /// WHERE something applies rather than WHAT it is, and at 16% opacity it was
    /// already rendering as #3b3029 — a warm near-grey. The legend swatch was
    /// drawn at full strength, so it was also advertising a colour the chart
    /// never showed. `slowerColor` keeps every text and bar use and is now a
    /// pure status colour, which is what it should always have been.
    ///
    /// CHOSEN BY SEARCH. Slate clears every colour it can share a surface with:
    ///
    ///     dark  #8C86A0   worst ΔE 17.4 normal · 17.5 CVD
    ///     light #8888AC   worst ΔE 18.0 normal · 18.0 CVD
    ///
    /// Cool rather than warm because warm is exactly what is full. On light,
    /// warm neutrals collide with `atlTint` #B07D00: of every low-chroma hex
    /// that clears the light neighbours, none is warm.
    ///
    /// NOT compared against `fasterColor` — pace colours and monotony never
    /// share a chart, a legend or an ⓘ topic. Against it the dark step measures
    /// 13.1, which is stated here so nobody re-derives it as a fault.
    static let bandTint = dyn(dark: 0x8C86A0, light: 0x8888AC)

    /// Opacity for the band fill. Was 16% while the fill was warm; a cool grey
    /// on a cool card separates less at the same alpha, so it is 20% — which
    /// composites to #2F303B on dark against the old #3b3029, near enough the
    /// same weight on the page.
    static let bandFill = 0.20

    /// Past its service life rather than nearing it. Distinct from
    /// `slowerColor`, which marks the first threshold.
    ///
    /// CHOSEN BY MEASUREMENT, NOT BY EYE — on dark, against amber #F59E4D:
    ///
    ///     #F55959   ΔE 15.4 normal · 10.4 deutan   — clears the floor by 0.4
    ///     #FF3B30   ΔE 18.0 normal · 11.0 deutan
    ///     #F0443A   ΔE 18.0 normal · 13.0 deutan
    ///     #E5484D   ΔE 18.9 normal · 14.8 deutan   ← this one
    ///
    /// THE LIGHT STEP WAS BROKEN AND IS NOW FIXED — patch 141.
    ///
    /// It read #B3261E, and against the light amber #B45309 that measured ΔE 8.5
    /// normal / 5.5 deutan. Normal-vision separation below 15 is a hard failure
    /// rather than a soft one: it is not a colour-blindness problem, it is two
    /// colours a full-colour reader cannot reliably tell apart. Secondary
    /// encoding does not excuse it, which is why the words "worn" and "replace"
    /// beside the figures were never the answer — the shoe BAR and the two
    /// bands in the shoes ⓘ carry the distinction on hue alone.
    ///
    /// WHY THE RED MOVED AND NOT THE AMBER. `slowerColor` is load-bearing: it is
    /// one third of the validated pace triad, the monotony rule on two charts,
    /// and the wrong-direction colour on both load strips. `spentColor` has two
    /// call sites. Moving the amber towards yellow to open the gap would have
    /// re-opened the triad and changed the dark scheme with it.
    ///
    /// CHOSEN BY SEARCH, NOT BY EYE. Every hex in the red family that passes all
    /// five checks against #B45309 on the #F1F3F7 card was enumerated, then
    /// ranked by OKLab distance from the colour being replaced — the smallest
    /// move that clears the floor, so "replace" still reads as red rather than
    /// as magenta. Maximising separation instead walks to #800090, which is
    /// purple and says nothing.
    ///
    ///     #9F1239   ΔE 14.1 normal · 11.8 deutan   — still under the floor
    ///     #9B1C48   ΔE 15.0 normal · 13.1 deutan   — floor exactly, no margin
    ///     #9B0741   ΔE 16.0 normal · 13.6 deutan · 9.6 tritan   ← this one
    ///     #960246   ΔE 17.6 normal · 15.3 deutan   — more margin, visibly plum
    ///
    /// The DARK step is untouched: #E5484D against dark amber #F59E4D already
    /// measured 18.9 normal / 14.8 deutan and was never the problem.
    ///
    /// SIDE EFFECT, DELIBERATE. This no longer equals `dangerColor` on light,
    /// which it did by coincidence. They mean different things — "past its
    /// service life" is not "this will destroy something" — and nothing reads
    /// them as a pair.
    static let spentColor = dyn(dark: 0xE5484D, light: 0x9B0741)

    /// Destructive and alarming: the close button, a blocking flag, an over-cap
    /// fuel figure. Was written out as a literal at eleven call sites across six
    /// files, every one of them the same three floats — which meant a light
    /// scheme would have had to find all eleven.
    static let dangerColor = dyn(dark: 0xF55959, light: 0xB3261E)

    /// The long run's own violet. Shared by the fuel line and the plan volume
    /// chart, which is why it is here rather than declared twice.
    static let longRunTint = dyn(dark: 0x8C8CF2, light: 0x4740B8)

    /// Route start. Distinct from accent4 and always paired with the word
    /// "Start" on the annotation — never colour alone. Lived in RouteMapView
    /// until patch 174; a theme token in a feature file is the first step
    /// towards somebody who cannot find it declaring a second one.
    static let startColor = Discipline.run.tint

    /// The scrim behind an expanded panel, and the shadow under it. Black on a
    /// dark background is a deepening; on a white one it is a bruise. Both step
    /// back sharply on light.
    static var scrim: Color {
        Color(uiColor: UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(white: 0, alpha: 0.62)
                : UIColor(white: 0.10, alpha: 0.28)
        })
    }
    static var panelShadow: Color {
        Color(uiColor: UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(white: 0, alpha: 0.80)
                : UIColor(white: 0.30, alpha: 0.22)
        })
    }
}

extension Discipline {
    /// One definition of each sport's colour, shared by session rows and the
    /// plan-position card. Light values are the validated set — see the file
    /// header for the numbers.
    var tint: Color {
        switch self {
        case .strength: return .accent4
        case .bike:     return dyn(dark: 0x59C7D9, light: 0x0E8FA8)
        case .swim:     return dyn(dark: 0x619EF5, light: 0x2456C7)
        case .rest:     return dyn(dark: 0x737A8C, light: 0x8A91A0)
        case .other:    return .dim
        case .run:      return dyn(dark: 0x59D499, light: 0x0F7B5A)
        }
    }

    /// The commute band on the volume stack. On DARK it is the bike hue at 55%,
    /// a tint towards the background. On LIGHT that move fails three checks at
    /// once, so it takes its own hue and loses the family resemblance — the
    /// trade is documented in the file header.
    static var commuteTint: Color {
        Color(uiColor: UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(Discipline.bike.tint.opacity(0.55))
                : UIColor(red: 0.42, green: 0.31, blue: 0.62, alpha: 1)   // #6B4E9E
        })
    }
}

extension Session {
    /// Accent colour: run sessions colour by intensity, everything else by discipline.
    var tint: Color {
        switch discipline {
        case .strength, .bike, .swim, .rest, .other:
            return discipline.tint
        case .run:
            switch intensity {
            case .long:          return dyn(dark: 0x8C8CF2, light: 0x4740B8)
            case .marathonPace:  return dyn(dark: 0xF2738C, light: 0xB01E4C)
            case .threshold:     return dyn(dark: 0xF55959, light: 0xB3261E)
            case .easy, .none:   return dyn(dark: 0x59D499, light: 0x0F7B5A)
            }
        }
    }

    /// "Run · long" / "Strength"
    var kindLabel: String {
        guard discipline == .run, let i = intensity else { return discipline.label }
        switch i {
        case .easy:         return "Run · easy"
        case .long:         return "Run · long"
        case .threshold:    return "Run · threshold"
        case .marathonPace: return "Run · MP"
        }
    }
}

// MARK: - Heart-rate zones

extension AthleteStore.HRZone {
    /// Ordinal ramp, cool → warm. Always shown beside the "Z2" label, never as
    /// colour alone.
    /// DARK: five hues, cool → warm, because red says hard.
    /// LIGHT: a single-hue sequential ramp, because five hues do not separate on
    /// white — see the file header. The ramp says "more" rather than "harder",
    /// which is a real loss of meaning and the reason every bar carries its full
    /// name on both schemes.
    var color: Color {
        switch index {
        case 1:  return dyn(dark: 0x738CB3, light: 0x7FA6CF)   // recovery
        case 2:  return dyn(dark: 0x59D499, light: 0x5484BC)   // endurance
        case 3:  return dyn(dark: 0xF2BF59, light: 0x31629F)   // tempo
        case 4:  return dyn(dark: 0xF58C4D, light: 0x17457B)   // threshold
        default: return dyn(dark: 0xF55959, light: 0x072C52)   // VO2
        }
    }

    /// What the zone is FOR. One definition, used by the Progress axis, the
    /// chip on Today, both detail views and the stream caveat — so the five
    /// words cannot drift apart across surfaces.
    var name: String {
        switch index {
        case 1:  return "Recovery"
        case 2:  return "Endurance"
        case 3:  return "Tempo"
        case 4:  return "Threshold"
        default: return "VO₂"
        }
    }
}

/// "Z2 Endurance · 134" — identity carried by the label, colour only reinforces
/// it.
///
/// `showName` now defaults to TRUE. Every surface in the app names its zones as
/// of patch 78, so the flag survives only for a row too dense to take the word;
/// there is currently no such row, and a default that has to be switched on at
/// every call site is a default pointing the wrong way.
struct ZoneChip: View {
    let zone: AthleteStore.HRZone
    let bpm: Int
    var showName = true

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(zone.color).frame(width: 6, height: 6)
            Text(zone.label).font(.caption2.weight(.bold))
            if showName {
                Text(zone.name).font(.caption2)
            }
            Text("· \(bpm)").font(.caption2)
        }
        .foregroundStyle(zone.color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(zone.color.opacity(0.14))
        .clipShape(Capsule())
    }
}

// MARK: - Reusable card chrome

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Color.card)
            // On light, page and card are both white — the rule IS the card.
            // Kept at cornerRadius 14 on both so nothing else has to move.
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.line, lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardBackground()) }
}

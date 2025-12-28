import SwiftUI

struct StarfieldBackgroundView: View {
  private struct Star: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let r: CGFloat
    let a: CGFloat
  }

  @State private var stars: [Star] = makeInitialStars()

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color.black, Color(red: 0.05, green: 0.06, blue: 0.10)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      Canvas { ctx, size in
        for star in stars {
          let rect = CGRect(x: star.x * size.width, y: star.y * size.height, width: star.r, height: star.r)
          ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(star.a)))
        }
      }
      .ignoresSafeArea()
    }
  }

  private static func makeInitialStars() -> [Star] {
    var rng = SystemRandomNumberGenerator()
    return (0..<260).map { _ in
      Star(
        x: CGFloat.random(in: 0...1, using: &rng),
        y: CGFloat.random(in: 0...1, using: &rng),
        r: CGFloat.random(in: 1...2.2, using: &rng),
        a: CGFloat.random(in: 0.08...0.55, using: &rng)
      )
    }
  }
}




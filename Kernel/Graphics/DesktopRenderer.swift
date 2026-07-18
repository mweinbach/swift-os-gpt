enum DesktopRenderer {
    static func render(into framebuffer: LinearFramebuffer) {
        framebuffer.fill(.wallpaper)
        drawTopBar(on: framebuffer)
        drawTerminal(on: framebuffer)
        drawSystemPanel(on: framebuffer)
        drawRoadmapPanel(on: framebuffer)
        drawDock(on: framebuffer)
        AArch64.synchronizeData()
    }

    private static func drawTopBar(on framebuffer: LinearFramebuffer) {
        framebuffer.fill(Rectangle(x: 0, y: 0, width: 800, height: 34), color: .chrome)
        framebuffer.fill(Rectangle(x: 0, y: 34, width: 800, height: 2), color: .cyan)
        framebuffer.fill(Rectangle(x: 14, y: 8, width: 18, height: 18), color: .cyan)
        framebuffer.drawText("S", at: Point(x: 20, y: 10), color: .wallpaper)
        framebuffer.drawText(
            "SWIFTOS",
            at: Point(x: 42, y: 10),
            color: .white,
            scale: 2
        )
        framebuffer.drawText(
            "EL1  MMU ON  SWIFT NATIVE",
            at: Point(x: 530, y: 13),
            color: .muted
        )
    }

    private static func drawTerminal(on framebuffer: LinearFramebuffer) {
        framebuffer.fill(Rectangle(x: 54, y: 84, width: 470, height: 354), color: .shadow)
        framebuffer.fill(Rectangle(x: 48, y: 78, width: 470, height: 354), color: .terminal)
        framebuffer.stroke(Rectangle(x: 48, y: 78, width: 470, height: 354), color: .panel)
        framebuffer.fill(Rectangle(x: 49, y: 79, width: 468, height: 31), color: .panel)
        framebuffer.fill(Rectangle(x: 63, y: 91, width: 8, height: 8), color: .red)
        framebuffer.fill(Rectangle(x: 79, y: 91, width: 8, height: 8), color: .yellow)
        framebuffer.fill(Rectangle(x: 95, y: 91, width: 8, height: 8), color: .green)
        framebuffer.drawText("TERMINAL", at: Point(x: 232, y: 91), color: .muted)

        framebuffer.drawText(
            "SWIFT@METAL:~> UNAME -A",
            at: Point(x: 68, y: 132),
            color: .cyan
        )
        framebuffer.drawText(
            "SWIFTOS AARCH64 0.1",
            at: Point(x: 68, y: 153),
            color: .white
        )
        framebuffer.drawText(
            "SWIFT@METAL:~> STATUS",
            at: Point(x: 68, y: 184),
            color: .cyan
        )
        framebuffer.drawText("[OK] KERNEL OWNS EL1", at: Point(x: 68, y: 208), color: .green)
        framebuffer.drawText("[OK] MMU AND CACHES", at: Point(x: 68, y: 228), color: .green)
        framebuffer.drawText("[OK] NATIVE RAMFB", at: Point(x: 68, y: 248), color: .green)
        framebuffer.drawText("[OK] DEVICE TREE", at: Point(x: 68, y: 268), color: .green)
        framebuffer.drawText(
            "SWIFT@METAL:~> _",
            at: Point(x: 68, y: 306),
            color: .cyan
        )
    }

    private static func drawSystemPanel(on framebuffer: LinearFramebuffer) {
        framebuffer.fill(Rectangle(x: 554, y: 84, width: 208, height: 214), color: .shadow)
        framebuffer.fill(Rectangle(x: 548, y: 78, width: 208, height: 214), color: .chrome)
        framebuffer.stroke(Rectangle(x: 548, y: 78, width: 208, height: 214), color: .panel)
        framebuffer.drawText("SYSTEM", at: Point(x: 566, y: 96), color: .white, scale: 2)
        statusRow("CPU", value: "AARCH64", y: 135, on: framebuffer)
        statusRow("MODE", value: "KERNEL", y: 169, on: framebuffer)
        statusRow("VIDEO", value: "XRGB", y: 203, on: framebuffer)
        statusRow("LANG", value: "SWIFT", y: 237, on: framebuffer)
        framebuffer.fill(Rectangle(x: 566, y: 270, width: 172, height: 3), color: .cyan)
    }

    private static func statusRow(
        _ label: StaticString,
        value: StaticString,
        y: Int,
        on framebuffer: LinearFramebuffer
    ) {
        framebuffer.fill(Rectangle(x: 566, y: y, width: 172, height: 26), color: .panel)
        framebuffer.drawText(label, at: Point(x: 574, y: y + 9), color: .muted)
        framebuffer.drawText(value, at: Point(x: 646, y: y + 9), color: .white)
    }

    private static func drawRoadmapPanel(on framebuffer: LinearFramebuffer) {
        framebuffer.fill(Rectangle(x: 554, y: 326, width: 208, height: 126), color: .shadow)
        framebuffer.fill(Rectangle(x: 548, y: 320, width: 208, height: 126), color: .chrome)
        framebuffer.stroke(Rectangle(x: 548, y: 320, width: 208, height: 126), color: .panel)
        framebuffer.drawText("NEXT", at: Point(x: 566, y: 338), color: .white, scale: 2)
        framebuffer.drawText("IRQ TIMER", at: Point(x: 566, y: 374), color: .yellow)
        framebuffer.drawText("INPUT", at: Point(x: 566, y: 394), color: .yellow)
        framebuffer.drawText("EL0 TASKS", at: Point(x: 566, y: 414), color: .yellow)
    }

    private static func drawDock(on framebuffer: LinearFramebuffer) {
        framebuffer.fill(Rectangle(x: 194, y: 542, width: 412, height: 46), color: .shadow)
        framebuffer.fill(Rectangle(x: 188, y: 536, width: 412, height: 46), color: .chrome)
        framebuffer.stroke(Rectangle(x: 188, y: 536, width: 412, height: 46), color: .panel)

        dockIcon("T", x: 216, color: .cyan, on: framebuffer)
        dockIcon("F", x: 284, color: .blue, on: framebuffer)
        dockIcon("S", x: 352, color: .green, on: framebuffer)
        dockIcon("N", x: 420, color: .yellow, on: framebuffer)
        dockIcon(">", x: 488, color: .red, on: framebuffer)
        framebuffer.drawText("SWIFT TO METAL", at: Point(x: 520, y: 556), color: .muted)
    }

    private static func dockIcon(
        _ label: StaticString,
        x: Int,
        color: PixelColor,
        on framebuffer: LinearFramebuffer
    ) {
        framebuffer.fill(Rectangle(x: x, y: 544, width: 30, height: 30), color: color)
        framebuffer.drawText(label, at: Point(x: x + 10, y: 552), color: .wallpaper, scale: 2)
    }
}


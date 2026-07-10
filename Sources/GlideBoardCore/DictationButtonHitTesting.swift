import CoreGraphics

func dictationButtonWasPressed(at point: CGPoint,
                               buttonRect: CGRect,
                               helpVisible: Bool) -> Bool
{
    !helpVisible && buttonRect.insetBy(dx: -3, dy: -4).contains(point)
}

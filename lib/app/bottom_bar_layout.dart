import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Scrollable roots use this as trailing content padding, never viewport
/// padding: rows can paint under the bar and still scroll fully above it.
class BottomBarInset extends InheritedWidget {
  const BottomBarInset({super.key, required this.bottom, required super.child});

  final double bottom;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BottomBarInset>()?.bottom ?? 0;

  @override
  bool updateShouldNotify(BottomBarInset oldWidget) =>
      bottom != oldWidget.bottom;
}

/// Preserves the body element when switching between reserved and overlay
/// chrome. Measures the whole footer, including an optional music player.
class BottomBarLayout extends StatefulWidget {
  const BottomBarLayout({
    super.key,
    required this.overlay,
    required this.body,
    required this.footer,
  });

  final bool overlay;
  final Widget body;
  final Widget footer;

  @override
  State<BottomBarLayout> createState() => _BottomBarLayoutState();
}

class _BottomBarLayoutState extends State<BottomBarLayout> {
  double _footerHeight = 0;

  @override
  Widget build(BuildContext context) => CustomMultiChildLayout(
    delegate: _BottomBarDelegate(overlay: widget.overlay),
    children: [
      LayoutId(
        id: _BottomBarPart.body,
        child: BottomBarInset(
          bottom: widget.overlay ? _footerHeight : 0,
          child: widget.body,
        ),
      ),
      LayoutId(
        id: _BottomBarPart.footer,
        child: _FooterMeasure(
          onHeight: (height) {
            if (mounted && height != _footerHeight) {
              setState(() => _footerHeight = height);
            }
          },
          child: widget.footer,
        ),
      ),
    ],
  );
}

enum _BottomBarPart { body, footer }

class _BottomBarDelegate extends MultiChildLayoutDelegate {
  _BottomBarDelegate({required this.overlay});
  final bool overlay;

  @override
  void performLayout(Size size) {
    final footer = layoutChild(
      _BottomBarPart.footer,
      BoxConstraints(
        minWidth: size.width,
        maxWidth: size.width,
        maxHeight: size.height,
      ),
    );
    layoutChild(
      _BottomBarPart.body,
      BoxConstraints.tight(
        Size(size.width, overlay ? size.height : size.height - footer.height),
      ),
    );
    positionChild(_BottomBarPart.body, Offset.zero);
    positionChild(
      _BottomBarPart.footer,
      Offset(0, size.height - footer.height),
    );
  }

  @override
  bool shouldRelayout(_BottomBarDelegate oldDelegate) =>
      overlay != oldDelegate.overlay;
}

class _FooterMeasure extends SingleChildRenderObjectWidget {
  const _FooterMeasure({required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _FooterRender(onHeight);

  @override
  void updateRenderObject(BuildContext context, _FooterRender renderObject) {
    renderObject.onHeight = onHeight;
  }
}

class _FooterRender extends RenderProxyBox {
  _FooterRender(this.onHeight);
  ValueChanged<double> onHeight;
  double? _lastHeight;

  @override
  void performLayout() {
    super.performLayout();
    if (size.height == _lastHeight) return;
    _lastHeight = size.height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onHeight(size.height);
    });
  }
}

import 'package:flutter/material.dart';

class CropOverlay extends StatefulWidget {
  final double? targetAspectRatio;
  
  const CropOverlay({
    super.key,
    required this.targetAspectRatio,
  });

  @override
  State<CropOverlay> createState() => CropOverlayState();
}

class CropOverlayState extends State<CropOverlay> {
  Rect _rect = const Rect.fromLTWH(0.1, 0.1, 0.8, 0.8);
  
  Rect get currRect => _rect;

  @override
  void didUpdateWidget(CropOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.targetAspectRatio != oldWidget.targetAspectRatio) {
      _resetRect();
    }
  }

  void _resetRect() {
    setState(() {
      _rect = const Rect.fromLTWH(0.1, 0.1, 0.8, 0.8);
    });
  }

  void _updateRect(Rect newRect) {
    setState(() {
      // Clamp to 0-1 bounds
      _rect = Rect.fromLTWH(
        newRect.left.clamp(0.0, 1.0 - newRect.width),
        newRect.top.clamp(0.0, 1.0 - newRect.height),
        newRect.width.clamp(0.1, 1.0),
        newRect.height.clamp(0.1, 1.0),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        
        double rectW = w * _rect.width;
        double rectH = h * _rect.height;
        
        // Enforce aspect ratio if specified
        if (widget.targetAspectRatio != null) {
          if (w / h > widget.targetAspectRatio!) {
            rectH = h * 0.8;
            rectW = rectH * widget.targetAspectRatio!;
          } else {
            rectW = w * 0.8;
            rectH = rectW / widget.targetAspectRatio!;
          }
        }
        
        double l = (w - rectW) / 2;
        double t = (h - rectH) / 2;
        
        // Update normalized rect for aspect ratio enforcement
        final newNormRect = Rect.fromLTWH(l/w, t/h, rectW/w, rectH/h);
        if (widget.targetAspectRatio != null && _rect != newNormRect) {
          _rect = newNormRect;
        }

        return Stack(
          children: [
            // Darken outside
            Positioned.fill(
              child: CustomPaint(
                painter: _OverlayPainter(
                  cropRect: Rect.fromLTWH(l, t, rectW, rectH),
                ),
              ),
            ),
            
            // Crop box with handles
            Positioned(
              left: l,
              top: t,
              width: rectW,
              height: rectH,
              child: _CropBox(
                onMove: widget.targetAspectRatio == null ? (delta) {
                  final newLeft = _rect.left + delta.dx / w;
                  final newTop = _rect.top + delta.dy / h;
                  _updateRect(Rect.fromLTWH(
                    newLeft,
                    newTop,
                    _rect.width,
                    _rect.height,
                  ));
                } : null,
                onResize: widget.targetAspectRatio == null ? (alignment, delta) {
                  _handleResize(alignment, delta, w, h);
                } : null,
                isFreeMode: widget.targetAspectRatio == null,
              ),
            ),
          ],
        );
      },
    );
  }

  void _handleResize(Alignment alignment, Offset delta, double w, double h) {
    final dx = delta.dx / w;
    final dy = delta.dy / h;
    
    double newLeft = _rect.left;
    double newTop = _rect.top;
    double newWidth = _rect.width;
    double newHeight = _rect.height;

    // Top-left corner
    if (alignment == Alignment.topLeft) {
      newLeft += dx;
      newTop += dy;
      newWidth -= dx;
      newHeight -= dy;
    }
    // Top-right corner
    else if (alignment == Alignment.topRight) {
      newTop += dy;
      newWidth += dx;
      newHeight -= dy;
    }
    // Bottom-left corner
    else if (alignment == Alignment.bottomLeft) {
      newLeft += dx;
      newWidth -= dx;
      newHeight += dy;
    }
    // Bottom-right corner
    else if (alignment == Alignment.bottomRight) {
      newWidth += dx;
      newHeight += dy;
    }
    // Top edge
    else if (alignment == Alignment.topCenter) {
      newTop += dy;
      newHeight -= dy;
    }
    // Bottom edge
    else if (alignment == Alignment.bottomCenter) {
      newHeight += dy;
    }
    // Left edge
    else if (alignment == Alignment.centerLeft) {
      newLeft += dx;
      newWidth -= dx;
    }
    // Right edge
    else if (alignment == Alignment.centerRight) {
      newWidth += dx;
    }

    _updateRect(Rect.fromLTWH(newLeft, newTop, newWidth, newHeight));
  }
}

class _CropBox extends StatelessWidget {
  final Function(Offset)? onMove;
  final Function(Alignment, Offset)? onResize;
  final bool isFreeMode;

  const _CropBox({
    this.onMove,
    this.onResize,
    required this.isFreeMode,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Grid (removed explicit border)
        Column(
            children: [
              Expanded(child: Row(children: [
                Expanded(child: Container(decoration: const BoxDecoration(border: Border(right: BorderSide(color: Colors.white24, width: 0.5), bottom: BorderSide(color: Colors.white24, width: 0.5))))),
                Expanded(child: Container(decoration: const BoxDecoration(border: Border(left: BorderSide(color: Colors.white24, width: 0.5), bottom: BorderSide(color: Colors.white24, width: 0.5))))),
              ])),
              Expanded(child: Row(children: [
                Expanded(child: Container(decoration: const BoxDecoration(border: Border(right: BorderSide(color: Colors.white24, width: 0.5), top: BorderSide(color: Colors.white24, width: 0.5))))),
                Expanded(child: Container(decoration: const BoxDecoration(border: Border(left: BorderSide(color: Colors.white24, width: 0.5), top: BorderSide(color: Colors.white24, width: 0.5))))),
              ])),
            ],
          ),
        
        // Center drag handle (only in free mode)
        if (isFreeMode && onMove != null)
          Center(
            child: GestureDetector(
              onPanUpdate: (details) => onMove!(details.delta),
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.drag_indicator, color: Colors.white54, size: 30),
              ),
            ),
          ),
        
        // Resize handles (only in free mode)
        if (isFreeMode && onResize != null) ...[
          // Corners
          _buildHandle(Alignment.topLeft, onResize!, isCorner: true),
          _buildHandle(Alignment.topRight, onResize!, isCorner: true),
          _buildHandle(Alignment.bottomLeft, onResize!, isCorner: true),
          _buildHandle(Alignment.bottomRight, onResize!, isCorner: true),
          
          // Edges
          _buildHandle(Alignment.topCenter, onResize!, isCorner: false),
          _buildHandle(Alignment.bottomCenter, onResize!, isCorner: false),
          _buildHandle(Alignment.centerLeft, onResize!, isCorner: false),
          _buildHandle(Alignment.centerRight, onResize!, isCorner: false),
        ],
      ],
    );
  }

  Widget _buildHandle(Alignment alignment, Function(Alignment, Offset) onResize, {required bool isCorner}) {
    return Align(
      alignment: alignment,
      child: GestureDetector(
        onPanUpdate: (details) => onResize(alignment, details.delta),
        child: Container(
          width: isCorner ? 20 : 6,
          height: isCorner ? 20 : 20,
          decoration: BoxDecoration(
            color: Colors.white70,
            shape: isCorner ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: isCorner ? null : BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final Rect cropRect;
  _OverlayPainter({required this.cropRect});
  
  @override
  void paint(Canvas canvas, Size size) {
    final Path path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(cropRect)
      ..fillType = PathFillType.evenOdd;
      
    canvas.drawPath(
      path, 
      Paint()..color = Colors.black.withValues(alpha: 0.7)
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

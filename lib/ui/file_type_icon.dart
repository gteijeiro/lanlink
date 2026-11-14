import 'package:flutter/material.dart';

enum FileCategory { image, video, audio, document, archive, code, other }

class FileVisual {
  const FileVisual(
    this.category,
    this.label,
    this.icon,
    this.color,
    this.extension,
  );
  final FileCategory category;
  final String label;
  final IconData icon;
  final Color color;
  final String extension;

  factory FileVisual.forName(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 && dot < name.length - 1
        ? name.substring(dot + 1).toLowerCase()
        : '';
    final (category, label, icon, color) = switch (ext) {
      'jpg' ||
      'jpeg' ||
      'png' ||
      'gif' ||
      'webp' ||
      'heic' ||
      'heif' ||
      'bmp' ||
      'svg' ||
      'tif' ||
      'tiff' ||
      'avif' ||
      'raw' => (
        FileCategory.image,
        'Imagen',
        Icons.landscape_rounded,
        const Color(0xff148980),
      ),
      'mp4' ||
      'mov' ||
      'm4v' ||
      'mkv' ||
      'webm' ||
      'avi' ||
      '3gp' ||
      'mpeg' ||
      'mpg' ||
      'mts' ||
      'm2ts' => (
        FileCategory.video,
        'Video',
        Icons.play_arrow_rounded,
        const Color(0xff7756c9),
      ),
      'mp3' ||
      'm4a' ||
      'aac' ||
      'wav' ||
      'flac' ||
      'ogg' ||
      'opus' ||
      'aiff' ||
      'wma' => (
        FileCategory.audio,
        'Audio',
        Icons.graphic_eq_rounded,
        const Color(0xffbe5088),
      ),
      'pdf' => (
        FileCategory.document,
        'PDF',
        Icons.picture_as_pdf_rounded,
        const Color(0xffce5259),
      ),
      'doc' || 'docx' || 'odt' || 'rtf' => (
        FileCategory.document,
        'Documento',
        Icons.article_rounded,
        const Color(0xff3c75cb),
      ),
      'xls' || 'xlsx' || 'ods' || 'csv' || 'numbers' => (
        FileCategory.document,
        'Planilla',
        Icons.table_chart_rounded,
        const Color(0xff27875e),
      ),
      'ppt' || 'pptx' || 'odp' || 'key' => (
        FileCategory.document,
        'Presentación',
        Icons.slideshow_rounded,
        const Color(0xffc17732),
      ),
      'txt' || 'md' || 'log' => (
        FileCategory.document,
        'Texto',
        Icons.notes_rounded,
        const Color(0xff607b9b),
      ),
      'zip' || 'rar' || '7z' || 'tar' || 'gz' || 'bz2' || 'xz' || 'tgz' => (
        FileCategory.archive,
        'Comprimido',
        Icons.inventory_2_rounded,
        const Color(0xffb38328),
      ),
      'json' ||
      'xml' ||
      'html' ||
      'css' ||
      'js' ||
      'ts' ||
      'py' ||
      'dart' ||
      'swift' ||
      'kt' ||
      'java' ||
      'cpp' ||
      'sh' ||
      'yaml' ||
      'yml' => (
        FileCategory.code,
        'Código',
        Icons.code_rounded,
        const Color(0xff5471a4),
      ),
      _ => (
        FileCategory.other,
        'Archivo',
        Icons.insert_drive_file_rounded,
        const Color(0xff708397),
      ),
    };
    return FileVisual(category, label, icon, color, ext.toUpperCase());
  }
}

/// A vector document silhouette with a folded corner, category glyph and format.
class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon({super.key, required this.name, this.size = 58});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final visual = FileVisual.forName(name);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final label = visual.extension.isEmpty ? 'FILE' : visual.extension;
    return Semantics(
      label:
          '${visual.label}${visual.extension.isEmpty ? '' : ' ${visual.extension}'}',
      image: true,
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size * 1.12,
          child: CustomPaint(
            painter: _DocumentPainter(visual.color, dark),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 5),
                Icon(
                  visual.icon,
                  color: dark
                      ? Color.lerp(visual.color, Colors.white, .45)
                      : visual.color,
                  size: size * .43,
                ),
                const SizedBox(height: 3),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label.length > 6 ? '${label.substring(0, 5)}…' : label,
                      style: TextStyle(
                        color: dark ? Colors.white70 : visual.color,
                        fontSize: size * .165,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .7,
                      ),
                      textScaler: TextScaler.noScaling,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DocumentPainter extends CustomPainter {
  _DocumentPainter(this.color, this.dark);
  final Color color;
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    final fold = size.width * .25;
    final rect = Rect.fromLTWH(3, 1, size.width - 6, size.height - 2);
    final body = Path()
      ..moveTo(rect.left + 9, rect.top)
      ..lineTo(rect.right - fold, rect.top)
      ..lineTo(rect.right, rect.top + fold)
      ..lineTo(rect.right, rect.bottom - 9)
      ..quadraticBezierTo(rect.right, rect.bottom, rect.right - 9, rect.bottom)
      ..lineTo(rect.left + 9, rect.bottom)
      ..quadraticBezierTo(rect.left, rect.bottom, rect.left, rect.bottom - 9)
      ..lineTo(rect.left, rect.top + 9)
      ..quadraticBezierTo(rect.left, rect.top, rect.left + 9, rect.top)
      ..close();
    canvas.drawPath(
      body,
      Paint()..color = color.withValues(alpha: dark ? .22 : .10),
    );
    canvas.drawPath(
      body,
      Paint()
        ..color = color.withValues(alpha: .25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final corner = Path()
      ..moveTo(rect.right - fold, rect.top)
      ..lineTo(rect.right - fold, rect.top + fold - 4)
      ..quadraticBezierTo(
        rect.right - fold,
        rect.top + fold,
        rect.right - fold + 4,
        rect.top + fold,
      )
      ..lineTo(rect.right, rect.top + fold)
      ..close();
    canvas.drawPath(
      corner,
      Paint()..color = color.withValues(alpha: dark ? .45 : .22),
    );
  }

  @override
  bool shouldRepaint(_DocumentPainter oldDelegate) =>
      color != oldDelegate.color || dark != oldDelegate.dark;
}

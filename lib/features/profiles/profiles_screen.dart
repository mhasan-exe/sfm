import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/widgets/glass_card.dart';
import '../../core/theme/app_theme.dart';

import '../../core/services/admin_config_service.dart';
import '../../core/services/user_service.dart';

import '../../models/user_model.dart';
import '../timetable/teacher_timetable_screen.dart';

class ProfilesScreen extends StatelessWidget {
  const ProfilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: AdminConfigService().getMaxUnitsPerTeacher(),
      builder: (context, maxUnitsSnap) {
        final maxUnits = maxUnitsSnap.data ?? 24;
        return StreamBuilder<List<UserModel>>(
          stream: UserService().watchTeachers(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 40, color: Colors.redAccent),
                      const SizedBox(height: 12),
                      const Text(
                        'Couldn\'t load teacher profiles',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
                      ),
                    ],
                  ),
                ),
              );
            }

            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final teachers = snapshot.data!;

            if (teachers.isEmpty) {
              return const Center(child: Text('No Teachers Found'));
            }

            return LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 900;
                final crossAxisCount = isWide ? 3 : 1;

                return GridView.builder(
                  padding: AppTheme.pagePadding(context),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    // A fixed, generous height instead of an aspect ratio: the
                    // card's content (avatar row + two stat chips + a progress
                    // bar + two action buttons) doesn't scale with width, so a
                    // ratio-based height was overflowing on narrower phones.
                    mainAxisExtent: 268,
                  ),
                  itemCount: teachers.length,
                  itemBuilder: (context, index) {
                    final teacher = teachers[index];
                    return _TeacherCard(teacher: teacher, maxUnits: maxUnits)
                        .animate()
                        .fadeIn(duration: 400.ms)
                        .slideY(begin: 0.1);
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _TeacherCard extends StatelessWidget {
  final UserModel teacher;
  final int maxUnits;

  const _TeacherCard({required this.teacher, required this.maxUnits});

  void _openTimetable(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(teacher.name)),
          body: TeacherTimetableScreen(
            teacherId: teacher.uid,
            teacherName: teacher.name,
          ),
        ),
      ),
    );
  }

  void _showProfileSheet(BuildContext context) {
    final total = teacher.defaultUnits + teacher.fixtureUnits;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(ctx).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _SafeAvatar(photoUrl: teacher.photoUrl, radius: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(teacher.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      Text(teacher.email, style: TextStyle(color: Colors.grey.shade400)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _detailRow('Role', teacher.role),
            _detailRow('Default units / week', '${teacher.defaultUnits}'),
            _detailRow('Fixture (cover) units / week', '${teacher.fixtureUnits}'),
            _detailRow('Total weekly load', '$total / $maxUnits'),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _openTimetable(context);
                },
                icon: const Icon(Icons.calendar_month),
                label: const Text('View Full Timetable'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade400)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = teacher.defaultUnits + teacher.fixtureUnits;

    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _SafeAvatar(photoUrl: teacher.photoUrl, radius: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        teacher.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        teacher.email,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'timetable') _openTimetable(context);
                    if (value == 'profile') _showProfileSheet(context);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'timetable', child: Text('Open Timetable')),
                    PopupMenuItem(value: 'profile', child: Text('View Profile')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _StatChip(title: 'Default', value: '${teacher.defaultUnits}', color: Colors.amber),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatChip(title: 'Fixtures', value: '${teacher.fixtureUnits}', color: Colors.redAccent),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Text('Weekly Load', style: TextStyle(fontSize: 12)),
                const Spacer(),
                Text('$total / $maxUnits', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: LinearProgressIndicator(
                value: (total / maxUnits).clamp(0, 1),
                minHeight: 10,
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                valueColor: AlwaysStoppedAnimation(total >= maxUnits ? Colors.red : Colors.blue),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _openTimetable(context),
                    icon: const Icon(Icons.calendar_month, size: 18),
                    label: const Text('Timetable'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showProfileSheet(context),
                    icon: const Icon(Icons.badge_outlined, size: 18),
                    label: const Text('Profile'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// CircleAvatar with a remote image crashes the whole render tree if the
/// image fails to load (e.g. Google's profile photo CDN rate-limiting with
/// a 429) — `backgroundImage` has no built-in fallback. This widget catches
/// that and falls back to a plain person icon instead.
class _SafeAvatar extends StatefulWidget {
  final String? photoUrl;
  final double radius;

  const _SafeAvatar({required this.photoUrl, required this.radius});

  @override
  State<_SafeAvatar> createState() => _SafeAvatarState();
}

class _SafeAvatarState extends State<_SafeAvatar> {
  bool _failed = false;

  @override
  void didUpdateWidget(_SafeAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photoUrl != widget.photoUrl) {
      _failed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final showImage = !_failed && widget.photoUrl != null && widget.photoUrl!.isNotEmpty;
    return CircleAvatar(
      radius: widget.radius,
      backgroundImage: showImage ? NetworkImage(widget.photoUrl!) : null,
      onBackgroundImageError: showImage
          ? (_, __) {
              if (mounted) setState(() => _failed = true);
            }
          : null,
      child: showImage ? null : const Icon(Icons.person),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String title;
  final String value;
  final Color color;

  const _StatChip({required this.title, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: Colors.grey.shade400, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }
}

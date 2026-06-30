import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/widgets/glass_card.dart';
import '../../core/theme/app_theme.dart';

import '../../core/services/admin_config_service.dart';
import '../../core/services/admin_service.dart';
import '../../core/services/user_service.dart';

import '../../models/user_model.dart';
import '../timetable/teacher_timetable_screen.dart';

class ProfilesScreen extends StatefulWidget {
  const ProfilesScreen({super.key});

  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  bool _isAdmin = false;
  bool _resyncing = false;

  @override
  void initState() {
    super.initState();
    AdminService().isAdmin().then((value) {
      if (mounted) setState(() => _isAdmin = value);
    });
  }

  Future<void> _resyncTeachers() async {
    setState(() => _resyncing = true);
    try {
      final result = await AdminService().resyncTeachersFromAuth();
      final created = result['created'] ?? 0;
      final total = result['totalAuthUsers'] ?? 0;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            created > 0
                ? 'Re-sync complete: created $created missing profile(s) out of $total Auth account(s).'
                : 'Re-sync complete: every Auth account ($total) already has a profile.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Re-sync failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _resyncing = false);
    }
  }

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
                      // If this shows "permission-denied", the signed-in account's
                      // email isn't covered by the @akesp.net allow-list in
                      // Firestore rules' isAllowedDomain() — that's the rules
                      // doing their job, not a bug in this screen.
                      if (_isAdmin) ...[
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: _resyncing ? null : _resyncTeachers,
                          icon: _resyncing
                              ? const SizedBox(
                                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.sync),
                          label: const Text('Re-sync teachers from Auth'),
                        ),
                      ],
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
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('No Teachers Found'),
                    if (_isAdmin) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _resyncing ? null : _resyncTeachers,
                        icon: _resyncing
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.sync),
                        label: const Text('Re-sync teachers from Auth'),
                      ),
                    ],
                  ],
                ),
              );
            }

            // Live, computed-from-weekly_timetables permanent unit count
            // for every teacher in ONE query — this is the actual fix for
            // "profile page doesn't show calculated units". The
            // `defaultUnits` field on each teacher's user doc is never
            // recalculated when their schedule changes (see UserService
            // for the full story), so the cards used to always show
            // whatever it was last manually reset to — usually 0.
            return FutureBuilder<Map<String, int>>(
              future: UserService().getLivePermanentUnitsForAllTeachers(),
              builder: (context, unitsSnap) {
                final liveUnits = unitsSnap.data ?? const {};

                return LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth > 900;
                    final crossAxisCount = isWide ? 3 : 1;

                    return Column(
                      children: [
                        if (_isAdmin)
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                                AppTheme.pagePadding(context).horizontal / 2, 12, AppTheme.pagePadding(context).horizontal / 2, 0),
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: _resyncing ? null : _resyncTeachers,
                                icon: _resyncing
                                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.sync, size: 18),
                                label: const Text('Re-sync from Auth'),
                              ),
                            ),
                          ),
                        Expanded(
                          child: GridView.builder(
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
                              return _TeacherCard(
                                teacher: teacher,
                                maxUnits: maxUnits,
                                livePermanentUnits: liveUnits[teacher.uid] ?? 0,
                                isAdmin: _isAdmin,
                              )
                                  .animate()
                                  .fadeIn(duration: 400.ms)
                                  .slideY(begin: 0.1);
                            },
                          ),
                        ),
                      ],
                    );
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
  final int livePermanentUnits;
  final bool isAdmin;

  const _TeacherCard({
    required this.teacher,
    required this.maxUnits,
    required this.livePermanentUnits,
    this.isAdmin = false,
  });

  Future<void> _deleteTeacher(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete teacher?'),
        content: Text(
          'This removes ${teacher.name}\'s profile, takes them off every class\'s '
          'unit config, and clears any timetable slots assigned to them. '
          'This does NOT delete their sign-in account — if they sign in again, '
          'a fresh blank profile will be created automatically.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await AdminService().deleteTeacher(teacher.uid);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${teacher.name} deleted.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: $e')),
      );
    }
  }

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
    final total = livePermanentUnits + teacher.fixtureUnits;
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
            _detailRow('Permanent units / week', '$livePermanentUnits'),
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
    final total = livePermanentUnits + teacher.fixtureUnits;

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
                    if (value == 'delete') _deleteTeacher(context);
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'timetable', child: Text('Open Timetable')),
                    const PopupMenuItem(value: 'profile', child: Text('View Profile')),
                    if (isAdmin)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete Teacher', style: TextStyle(color: Colors.redAccent)),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _StatChip(title: 'Permanent', value: '$livePermanentUnits', color: Colors.amber),
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

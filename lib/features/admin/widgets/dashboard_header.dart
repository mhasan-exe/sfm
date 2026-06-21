import 'package:flutter/material.dart';

class DashboardHeader
    extends StatelessWidget {
  const DashboardHeader({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,

            children: [
              Text(
                'Admin Dashboard',

                style: TextStyle(
                  fontSize: 30,

                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              SizedBox(height: 6),

              Text(
                'Manage classes, timetables and fixtures.',
              ),
            ],
          ),
        ),

        Container(
          padding:
              const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 12,
          ),

          decoration: BoxDecoration(
            color:
                Colors.blue.withValues(
              alpha: 0.15,
            ),

            borderRadius:
                BorderRadius.circular(
              18,
            ),
          ),

          child: const Row(
            children: [
              Icon(Icons.bolt),

              SizedBox(width: 8),

              Text('Realtime Sync'),
            ],
          ),
        )
      ],
    );
  }
}
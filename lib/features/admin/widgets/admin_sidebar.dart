import 'package:flutter/material.dart';

class AdminSidebar extends StatelessWidget {
  final int selectedIndex;

  final Function(int) onTap;

  const AdminSidebar({
    super.key,

    required this.selectedIndex,

    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final items = [
      'Dashboard',
      'Classes',
      'Timetables',
      'Fixtures',
      'Leaves',
      'Logs',
    ];

    final icons = [
      Icons.dashboard,
      Icons.school,
      Icons.table_chart,
      Icons.swap_horiz,
      Icons.event_busy,
      Icons.history,
    ];

    return Container(
      width: 260,

      padding: const EdgeInsets.all(20),

      decoration: BoxDecoration(
        color: const Color(0xFF171A22),

        border: Border(
          right: BorderSide(
            color:
                Colors.white.withValues(
              alpha: 0.05,
            ),
          ),
        ),
      ),

      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,

        children: [
          const SizedBox(height: 20),

          const Text(
            'AKESP Admin',

            style: TextStyle(
              fontSize: 24,

              fontWeight:
                  FontWeight.bold,
            ),
          ),

          const SizedBox(height: 40),

          ...List.generate(
            items.length,
            (index) {
              final selected =
                  selectedIndex ==
                      index;

              return Padding(
                padding:
                    const EdgeInsets.only(
                  bottom: 10,
                ),

                child: InkWell(
                  borderRadius:
                      BorderRadius.circular(
                    18,
                  ),

                  onTap: () {
                    onTap(index);
                  },

                  child: AnimatedContainer(
                    duration:
                        const Duration(
                      milliseconds: 250,
                    ),

                    padding:
                        const EdgeInsets.all(
                      16,
                    ),

                    decoration:
                        BoxDecoration(
                      color: selected
                          ? const Color(
                              0xFF4F8CFF,
                            )
                          : Colors
                              .transparent,

                      borderRadius:
                          BorderRadius
                              .circular(
                        18,
                      ),
                    ),

                    child: Row(
                      children: [
                        Icon(
                          icons[index],
                        ),

                        const SizedBox(
                          width: 14,
                        ),

                        Text(
                          items[index],
                        )
                      ],
                    ),
                  ),
                ),
              );
            },
          )
        ],
      ),
    );
  }
}
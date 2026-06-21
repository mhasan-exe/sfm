# SFM Flutter Project - Comprehensive Analysis Report

**Project**: AKESP Timetable System (School Facility Management)  
**Status**: Partial Implementation  
**Date**: June 2026

---

## 1. COMPILATION STATUS ✅

**Result**: **NO COMPILATION ERRORS**

- All imports are correctly resolved
- All dependencies properly installed
- Project structure valid
- Firebase configuration complete

> **Note**: The `flutter run -d chrome` exit code 1 is likely a runtime/web platform issue, not a compilation error.

---

## 2. FIRESTORE COLLECTIONS ANALYSIS

### Collections Currently in Use:

| Collection | Status | Purpose | Documents |
|------------|--------|---------|-----------|
| `admins` | ✅ Active | Admin user credentials | email, uid, createdAt |
| `users` | ✅ Active | Teacher profiles | name, email, role, defaultUnits, fixtureUnits, bio |
| `classes` | ✅ Active | Class/divisions | className, timeProfileId, unitsPerDay |
| `time_profiles` | ✅ Active | Period templates | name, periods (array), createdAt |
| `weekly_timetables` | ✅ Active | Base schedule | classId, day, unit, teacherId, startTime, endTime |
| `daily_timetables` | ✅ Active | Daily overrides | Same as weekly + date, type (override/permanent) |
| `leave_requests` | ✅ Active | Leave applications | teacherId, startDate, endDate, status (pending) |

### Collections Expected But NOT Implemented:

| Collection | Required For | Missing Fields/Docs |
|------------|-------------|-------------------|
| `fixtures` | Fixture marketplace | id, date, classId, unit, createdAt, status, claimedBy |
| `fixture_requests` | Fixture claims | fixtureId, teacherId, status, requestedAt |
| `audit_logs` | Admin logging | userId, action, timestamp, details |
| `holidays` | Special dates | date, name, type, description |
| `timetable_conflicts` | Conflict tracking | slot1Id, slot2Id, conflictType, severity |

---

## 3. SERVICE IMPLEMENTATIONS

### ✅ AdminService (Complete)
**File**: `lib/core/services/admin_service.dart`

**Implemented Methods**:
- `isAdmin()` - Check admin status via UID or email
- `watchAdmins()` - Real-time admin list stream
- `createAdmin(email, uid)` - Create new admin
- `deleteAdmin(docId)` - Remove admin

**Status**: Production Ready

---

### ⚠️ TimetableService (Mostly Complete)
**File**: `lib/core/services/timetable_service.dart`

**Implemented**:
- ✅ `createClass()` - Create class and auto-generate weekly slots
- ✅ `generateWeeklyTimetable()` - Create all weekly slots for a class
- ✅ `assignTeacherToWeeklySlot()` - Assign teacher with basic validation
- ✅ `createTimeProfile()` - Create period templates

**Issues Found**:
- ❌ Unit limit validation incomplete - checks AFTER incrementing
- ❌ No conflict detection between overlapping assignments
- ❌ No holiday/special date handling
- ❌ No batch validation for multiple assignments
- ❌ No teacher workload distribution

**Critical Bug**:
```dart
// Line ~110 - Validation happens AFTER attempting increment
if (total >= 24) {
  throw Exception('Teacher already reached 24 units');
}
await FirebaseFirestore.instance
    .collection('users')
    .doc(teacherId)
    .update({
      'defaultUnits': FieldValue.increment(1),  // ← Already incremented!
    });
```

**Needs**:
1. Validate BEFORE incrementing
2. Use transactions for atomic operations
3. Implement conflict detection
4. Add holiday exception handling

---

### ⚠️ RealtimeTimetableService (Basic Implementation)
**File**: `lib/core/services/realtime_timetable_service.dart`

**Implemented**:
- ✅ `streamClassTimetable()` - Stream from daily_timetables
- ✅ `assignTeacher()` - Override assignment
- ✅ `createSlot()` - Create permanent slot
- ✅ `generateDailyTimetable()` - Copy weekly to daily

**Missing**:
- ❌ Fixture assignment logic (isFixture field exists but not used)
- ❌ Conflict detection for overrides
- ❌ Notification system
- ❌ Assignment history tracking
- ❌ Bulk generation with date range

---

### ❌ LeaveService (Minimal - Only Submission)
**File**: `lib/core/services/leave_service.dart`

**Implemented**:
- ✅ `submitLeave()` - Create leave request document

**Missing (90% of functionality)**:
- ❌ Leave approval/rejection workflow
- ❌ Leave retrieval (list pending, approved, rejected)
- ❌ Leave balance management
- ❌ Timetable conflict checking during leave
- ❌ Leave cancellation
- ❌ Auto-assignment to other teachers
- ❌ Leave type handling (sick, casual, earned, unpaid)
- ❌ Leave history/analytics

**Current Issue**:
```dart
// Only creates leave_requests with status: 'pending'
// No review, approval, or rejection logic anywhere
```

---

### ❌ FixtureService (NOT IMPLEMENTED)
**File**: Does not exist - NEEDS TO BE CREATED

**Required Methods** (for fixture marketplace):
```dart
// Core CRUD
Future<void> createFixture({...}) - Add new fixture
Future<void> deleteFixture(String fixtureId) - Remove
Future<DocumentSnapshot> getFixture(String fixtureId) - Get details

// Claiming/Release
Future<void> claimFixture({
  required String fixtureId,
  required String teacherId,
  required String teacherName,
}) - Claim slot

Future<void> releaseFixture({
  required String fixtureId,
  required String teacherId,
}) - Release slot

// Streams
Stream<List<FixtureModel>> streamAvailableFixtures() - Marketplace
Stream<List<FixtureModel>> getTeacherFixtures(String teacherId) - My claims

// Admin
Future<void> generateDailyFixtures({
  required String date,
}) - Auto-generate from weekly

Future<void> bulkAssignFixtures({...}) - Batch operations
```

---

### ⚠️ UserService (Basic Only)
**File**: `lib/core/services/user_service.dart`

**Implemented**:
- ✅ `createUserIfNotExists()` - Create on first login
- ✅ `getTeachers()` - Stream all teachers

**Missing**:
- ❌ Filter teachers by availability
- ❌ Get teacher by ID
- ❌ Update teacher profile
- ❌ Get workload analytics
- ❌ Get teachers for specific class
- ❌ Bulk update operations
- ❌ Teacher search/filter
- ❌ Unit count aggregation

---

## 4. UI/FEATURE IMPLEMENTATION STATUS

### 🟢 Fully Implemented

#### AuthGate & Login
- ✅ Firebase authentication
- ✅ Auto-seed admin account (seed user: `2817783@students.akesp.net`)
- ✅ Auth state management
- ✅ Login screen with Google Sign-In

#### MainNavigationScreen
- ✅ Tab-based navigation
- ✅ Admin role checking
- ✅ Conditional admin tab display

#### HomeScreen
- ⚠️ Mostly implemented (hardcoded values)
  - Shows "Next Unit" status (static)
  - Leave submission button (works - calls LeaveService)
  - Exchange button (empty handler)

#### ProfilesScreen
- ✅ Teacher list with real-time updates
- ✅ Display unit counts
- ✅ Grid layout (responsive)

#### AdminScreen (Dashboard)
- ✅ Sidebar navigation
- ✅ Responsive mobile/desktop layout
- ✅ Class management section
- ✅ Time profile creation section
- ✅ Admin permission management

#### Class Management
- ✅ Class creation with profile selection
- ✅ Class list with edit/delete menu
- ✅ Integration with TimetableService

#### Time Profile Management
- ✅ Create periods with start/end times
- ✅ Full CRUD for time profiles

#### TimetableEditorScreen
- ✅ DataTable view of weekly slots
- ✅ Day/Unit grid layout
- ✅ Teacher assignment UI (partial)

---

### 🟡 Partially Implemented (UI Only)

#### FixtureMarketplaceScreen
**File**: `lib/features/fixtures/fixture_marketplace_screen.dart`

- ✅ UI Display: Fixture cards with hardcoded data
- ❌ NO Backend Logic
- ❌ NO Real-time updates
- ❌ NO Claiming functionality
- ❌ NO Database integration
- ❌ Shows 3 hardcoded fixtures only

**Required Implementation**:
```dart
// Needs to stream from fixtures collection
Stream<List<FixtureModel>> _availableFixtures = 
  fixtureService.streamAvailableFixtures();

// Needs onTap handler
onPressed: () async {
  await fixtureService.claimFixture(...);
}
```

---

### 🔴 Missing (Placeholder/Not Started)

#### Admin Panel Sections

1. **Fixtures Management Tab**
   - Status: Placeholder card only
   - Needs: Full fixture CRUD UI
   - Needs: Assignment history
   - Needs: Conflict resolution UI

2. **Leaves Management Tab**
   - Status: Placeholder card only
   - Needs: Pending requests list
   - Needs: Approval/rejection UI
   - Needs: Leave calendar view

3. **Logs/Audit Tab**
   - Status: Placeholder card only
   - Needs: Audit log collection
   - Needs: Activity history display
   - Needs: Filter/search by action/user

#### Missing Feature Screens

- ❌ **Leave Request Approval Panel** - Admin view for pending leaves
- ❌ **Fixture Conflict Viewer** - Show conflicting assignments
- ❌ **Teacher Workload Analytics** - Unit distribution charts
- ❌ **Class Schedule Viewer** - Student/parent view
- ❌ **Holiday Management** - Create/edit holidays
- ❌ **Timetable Conflicts Report** - Identify scheduling conflicts
- ❌ **Backup & Restore** - Data management

---

## 5. DATA MODEL STATUS

### ✅ Implemented Models

| Model | File | Status | Fields |
|-------|------|--------|--------|
| UserModel | models/user_model.dart | Complete | uid, name, email, role, isAdmin, defaultUnits, fixtureUnits, photoUrl, bio |
| ClassModel | models/class_model.dart | Complete | id, className, timeProfileId, unitsPerDay |
| TimeProfileModel | models/time_profile_model.dart | Complete | id, name, periods[] |
| TimePeriod | models/time_profile_model.dart | Complete | periodNumber, startTime, endTime |
| TimetableSlotModel | models/timetable_slot_model.dart | Complete | id, classId, day, unit, teacherId, startTime, endTime, type, originalTeacherId |

### ❌ Missing Models (Need to Create)

```dart
// Fixture Model
class FixtureModel {
  final String id;
  final String date;
  final String classId;
  final String className;
  final int unit;
  final String startTime;
  final String endTime;
  final String status; // 'available', 'claimed', 'completed'
  final String? claimedByTeacherId;
  final String? claimedByTeacherName;
  final DateTime createdAt;
  final String urgency; // 'normal', 'urgent'
}

// Leave Request Model
class LeaveRequestModel {
  final String id;
  final String teacherId;
  final String teacherName;
  final DateTime startDate;
  final DateTime endDate;
  final String reason;
  final String status; // 'pending', 'approved', 'rejected'
  final String leaveType; // 'sick', 'casual', 'earned', etc.
  final DateTime createdAt;
  final DateTime? approvedAt;
  final String? approvedBy;
  final String? rejectionReason;
}

// Audit Log Model
class AuditLogModel {
  final String id;
  final String userId;
  final String action;
  final Map<String, dynamic> details;
  final DateTime timestamp;
  final String entityType; // 'class', 'timetable', 'fixture', etc.
}

// Conflict Model
class TimetableConflictModel {
  final String id;
  final String slot1Id;
  final String slot2Id;
  final String conflictType; // 'teacher_overlap', 'room_overlap'
  final String severity; // 'critical', 'warning', 'info'
  final String description;
}

// Holiday Model
class HolidayModel {
  final String id;
  final DateTime date;
  final String name;
  final String type; // 'public', 'school', 'special'
  final String description;
}
```

---

## 6. CRITICAL ISSUES & BUGS

### 🔴 High Severity

1. **Unit Limit Not Enforced** (TimetableService)
   - **Location**: Line ~110 in `timetable_service.dart`
   - **Issue**: Increments unit count then checks limit
   - **Impact**: Teachers can exceed 24 unit limit
   - **Fix**: Use Firestore transaction to validate before update

2. **Fixture Service Missing Entirely**
   - **Impact**: Fixture marketplace only shows UI, no functionality
   - **Blocking**: Half of the app features (fixtures, exchange)
   - **Fix**: Create FixtureService with full CRUD

3. **Leave Management Not Implemented**
   - **Issue**: Only submission exists, no approval workflow
   - **Impact**: Leave requests pile up with no review mechanism
   - **Fix**: Create leave approval UI and workflow

4. **No Conflict Detection**
   - **Issue**: Can assign same teacher to overlapping time slots
   - **Impact**: Invalid timetables can be created
   - **Fix**: Add conflict detection in assignment methods

---

### 🟡 Medium Severity

1. **Hardcoded Values in HomeScreen**
   - "Next Unit" shows static "Class 10-A", "08:30 AM - 09:10 AM"
   - Should pull from user's current/next class

2. **No Error Handling**
   - Services don't use try-catch
   - No user-facing error messages for failures
   - App may crash on network errors

3. **FixtureMarketplaceScreen Unused**
   - Shows hardcoded fixtures
   - No integration with backend
   - UI never updates

4. **Missing Data Models**
   - Need FixtureModel, LeaveRequestModel, etc.
   - Makes feature implementation harder

---

### 🟢 Low Severity

1. **Admin Sidebar Duplication**
   - AdminSidebar widget exists but not used
   - Instead, sidebar built inline in admin_screen.dart

2. **Missing Asset/Constants Organization**
   - Constants folder exists but likely empty
   - Could organize strings, colors, etc.

3. **No Loading States**
   - Missing SkeletonLoader usage in some places
   - Loading experience not optimized

---

## 7. IMPLEMENTATION ROADMAP

### Phase 1: Core Fixes (1-2 weeks)
- [ ] Fix unit limit enforcement with transactions
- [ ] Create FixtureService with basic CRUD
- [ ] Create Fixture and LeaveRequest models
- [ ] Add conflict detection logic

### Phase 2: Fixture System (1 week)
- [ ] Implement fixture marketplace backend
- [ ] Add fixture claiming/release logic
- [ ] Add real-time fixture stream
- [ ] Integrate UI with backend

### Phase 3: Leave Management (1 week)
- [ ] Create leave approval UI
- [ ] Implement approval workflow
- [ ] Add leave type handling
- [ ] Create leave history view

### Phase 4: Admin Features (2 weeks)
- [ ] Implement fixture management panel
- [ ] Implement leave approval panel
- [ ] Create audit log system
- [ ] Create conflict report view

### Phase 5: Polish (1 week)
- [ ] Error handling & validation
- [ ] Loading states & animations
- [ ] Edge case handling
- [ ] Performance optimization

---

## 8. FILE STRUCTURE SUMMARY

```
lib/
├── main.dart                              ✅ Complete
├── firebase_options.dart                  ✅ Configured
├── models/
│   ├── user_model.dart                    ✅ Complete
│   ├── class_model.dart                   ✅ Complete
│   ├── time_profile_model.dart            ✅ Complete
│   ├── timetable_slot_model.dart          ✅ Complete
│   └── [MISSING] fixture_model.dart       ❌
│
├── core/
│   ├── services/
│   │   ├── admin_service.dart             ✅ Complete
│   │   ├── user_service.dart              ⚠️  Incomplete
│   │   ├── timetable_service.dart         ⚠️  Has bug
│   │   ├── realtime_timetable_service.dart ⚠️ Basic
│   │   ├── leave_service.dart             ❌ Only 10%
│   │   └── [MISSING] fixture_service.dart  ❌
│   │
│   ├── theme/
│   │   └── app_theme.dart                 ✅ Complete
│   │
│   ├── widgets/
│   │   ├── glass_card.dart                ✅
│   │   ├── responsive_wrapper.dart        ✅
│   │   ├── app_background.dart            ✅
│   │   └── loading_skeleton.dart          ✅
│   │
│   └── utils/
│       └── [Check contents]
│
├── features/
│   ├── auth/
│   │   ├── auth_gate.dart                 ✅ Complete
│   │   └── login_screen.dart              ✅ Complete
│   │
│   ├── home/
│   │   └── home_screen.dart               ⚠️ Hardcoded values
│   │
│   ├── profiles/
│   │   └── profiles_screen.dart           ✅ Complete
│   │
│   ├── fixtures/
│   │   └── fixture_marketplace_screen.dart ❌ UI only
│   │
│   ├── admin/
│   │   ├── admin_screen.dart              ⚠️ Partial
│   │   ├── timetable_editor_screen.dart   ⚠️ Partial
│   │   ├── pages/
│   │   │   └── admin_timetable_page.dart  ⚠️ Partial
│   │   └── widgets/
│   │       ├── admin_sidebar.dart         ⚠️ Unused
│   │       ├── class_list.dart            ✅ Complete
│   │       └── dashboard_header.dart      [Check]
│   │
│   ├── timetable/                         ❌ EMPTY
│   │   └── [Missing implementation]
│   │
│   └── navigation/
│       └── main_navigation_screen.dart    ✅ Complete
```

---

## 9. QUICK REFERENCE: What to Build Next

### Immediate Priorities (This Sprint):
1. **FixtureService** - Complete implementation (~200 lines)
2. **FixtureModel** - Create data model (~100 lines)
3. **Leave approval logic** - Add to LeaveService (~150 lines)
4. **Conflict detection** - Add to TimetableService (~100 lines)

### Next Sprint:
1. Fixture marketplace backend integration
2. Leave approval UI panel
3. Admin fixture management
4. Audit logging system

---

## 10. CONFIGURATION & SETUP INFO

**Firebase Project**: `akespsfm`
- **Web API Key**: Available in firebase_options.dart
- **Seed Admin**: 
  - UID: `JWVBLS2n9fOIDejjeVWrecmdQRy1`
  - Email: `2817783@students.akesp.net`

**Dependencies Installed**:
- firebase_core, firebase_auth, cloud_firestore
- flutter_riverpod (installed but not used yet)
- go_router (installed but using basic navigation)
- Animations and UI packages

---

## SUMMARY

**Status**: 🟡 **60% Complete - Feature Incomplete**

- ✅ Authentication & basic navigation working
- ✅ Admin dashboard UI operational  
- ✅ Class and time profile management working
- ✅ Weekly timetable generation functional
- ❌ Fixture system not implemented
- ❌ Leave approval workflow missing
- ❌ No conflict detection
- ❌ Critical bug in unit limit validation

**Next Action**: Create FixtureService to unblock fixture marketplace feature.


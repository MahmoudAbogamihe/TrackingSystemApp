import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'choose_location_to_edit_screen.dart';

Future<String?> uploadCompressedImageToAzure({
  required File file,
  required String containerName,
  required String fileName,
}) async {
  final String accountName = 'gp1storage2';
  final String sasToken =
      'sv=2024-11-04&ss=bfqt&srt=co&sp=rwdlacupiytfx&se=2027-02-16T22:26:06Z&st=2025-05-09T13:26:06Z&spr=https,http&sig=H%2BJaeH5Yu2EBBoblfSEfn%2BHWHZCPRza1XzAdhKZYCzE%3D';

  final safeContainerName =
      containerName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\-]'), '');
  final safeFileName = Uri.encodeComponent(fileName);

  final String url =
      'https://$accountName.blob.core.windows.net/$safeContainerName/$safeFileName?$sasToken';

  try {
    final imageBytes = await file.readAsBytes();
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) return null;

    final resized = img.copyResize(decoded, width: 512);
    final compressedBytes = img.encodeJpg(resized, quality: 60);

    final response = await http.put(
      Uri.parse(url),
      headers: {
        'x-ms-blob-type': 'BlockBlob',
        'x-ms-version': '2020-10-02',
        'Content-Type': 'image/jpeg',
        'Content-Length': compressedBytes.length.toString(),
      },
      body: compressedBytes,
    );

    if (response.statusCode == 201) {
      return url.split('?').first;
    } else {
      print('Failed to upload image to Azure: ${response.statusCode}');
      return null;
    }
  } catch (e) {
    print('Error uploading image to Azure: $e');
    return null;
  }
}

Future<bool> deleteImageFromAzure(String imageUrl) async {
  try {
    final uri = Uri.parse(imageUrl);
    final response = await http.delete(uri);

    if (response.statusCode == 202 || response.statusCode == 200) {
      print('Image deleted successfully from Azure');
      return true;
    } else {
      print('Failed to delete image from Azure: ${response.statusCode}');
      return false;
    }
  } catch (e) {
    print('Error deleting image from Azure: $e');
    return false;
  }
}

class EditProfileScreen extends StatefulWidget {
  static const String screenRoute = 'edit_profile_screen';
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late String username;
  late String oldEmployeeName;
  late Map<String, dynamic> info;

  final _formKey = GlobalKey<FormState>();
  late TextEditingController nameController;
  late TextEditingController phoneController;
  late TextEditingController addressController;
  late TextEditingController salaryController;
  late TextEditingController hoursController;
  late TextEditingController positionController;

  bool isSaving = false;
  bool locationSelected = false;

  Map<String, dynamic>? polygonFromDrawing;
  String? photoUrl;
  File? newImageFile;
  final ImagePicker picker = ImagePicker();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map<String, dynamic>) {
      username = args['username'] ?? '';
      oldEmployeeName = args['empName'] ?? '';
      info = Map<String, dynamic>.from(args['info'] ?? {});

      nameController = TextEditingController(text: oldEmployeeName);
      phoneController = TextEditingController(text: info['phone'] ?? '');
      addressController = TextEditingController(text: info['address'] ?? '');
      salaryController =
          TextEditingController(text: info['salary']?.toString() ?? '');
      hoursController =
          TextEditingController(text: info['working_hours']?.toString() ?? '');
      positionController = TextEditingController(text: info['position'] ?? '');
      photoUrl = info['photo_url'] ?? '';
    }
  }

  Future<void> pickImage() async {
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      setState(() => newImageFile = File(pickedFile.path));
    }
  }

  void updateData() async {
    if (_formKey.currentState!.validate()) {
      final newEmployeeName = nameController.text.trim();
      final oldEmployeeName = this.oldEmployeeName;

      if (newEmployeeName.contains(RegExp(r'[.$#[\]/]'))) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('اسم الموظف لا يمكن أن يحتوي على الرموز: . \$ # [ ] /'),
          ),
        );
        return;
      }

      bool nameChanged = newEmployeeName != oldEmployeeName;
      bool imageChanged = newImageFile != null;

      bool otherDataChanged = phoneController.text.trim() != info['phone'] ||
          addressController.text.trim() != info['address'] ||
          positionController.text.trim() != info['position'] ||
          int.tryParse(salaryController.text.trim()) != info['salary'] ||
          int.tryParse(hoursController.text.trim()) != info['working_hours'];

      if (!nameChanged &&
          !imageChanged &&
          !otherDataChanged &&
          polygonFromDrawing == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لم يتم تعديل أي بيانات.')),
        );
        return;
      }

      setState(() => isSaving = true); // ✅ بدل showDialog

      try {
        final db = FirebaseDatabase.instance;
        final oldRef = db.ref('$username/employees/$oldEmployeeName');
        final newRef = db.ref('$username/employees/$newEmployeeName');

        final oldInfoSnapshot = await oldRef.child('info').get();
        Map<String, dynamic> oldInfo = {};
        if (oldInfoSnapshot.exists) {
          oldInfo = Map<String, dynamic>.from(oldInfoSnapshot.value as Map);
        }

        String? updatedPhotoUrl = photoUrl;

        if (imageChanged) {
          final url = await uploadCompressedImageToAzure(
            file: newImageFile!,
            containerName: '$username-images',
            fileName: '$newEmployeeName.jpg',
          );
          if (url != null) {
            updatedPhotoUrl = url;
            if (photoUrl != null && photoUrl!.isNotEmpty) {
              await deleteImageFromAzure(photoUrl!);
            }
          }
        }

        if (nameChanged &&
            !imageChanged &&
            photoUrl != null &&
            photoUrl!.isNotEmpty) {
          try {
            final response = await http.get(Uri.parse(photoUrl!));
            if (response.statusCode == 200) {
              final tempDir = Directory.systemTemp;
              final tempFile = File('${tempDir.path}/temp_image.jpg');
              await tempFile.writeAsBytes(response.bodyBytes);

              final reuploadUrl = await uploadCompressedImageToAzure(
                file: tempFile,
                containerName: '$username-images',
                fileName: '$newEmployeeName.jpg',
              );

              if (reuploadUrl != null) {
                updatedPhotoUrl = reuploadUrl;
                await deleteImageFromAzure(photoUrl!);
              }
            }
          } catch (e) {
            print("❌ Error re-uploading image under new name: $e");
          }
        }

        String currentInLocation = 'Not exist now';
        try {
          final inLocationSnap = await oldRef.child('info/In Location').get();
          if (inLocationSnap.exists) {
            currentInLocation = inLocationSnap.value.toString();
          }
        } catch (e) {
          print('❌ Error fetching In Location: $e');
        }

        Map<String, dynamic> updatedData = {
          'phone': phoneController.text.trim(),
          'address': addressController.text.trim(),
          'salary': int.tryParse(salaryController.text.trim()) ?? 0,
          'working_hours': int.tryParse(hoursController.text.trim()) ?? 0,
          'position': positionController.text.trim(),
          'photo_url': updatedPhotoUrl ?? '',
          'In Location': currentInLocation,
        };

        List<List<int>>? newLocation;
        if (polygonFromDrawing != null &&
            polygonFromDrawing!['points'] != null &&
            polygonFromDrawing!['points'] is Map) {
          final pointsMap =
              polygonFromDrawing!['points'] as Map<String, dynamic>;
          if (pointsMap.isNotEmpty) {
            newLocation = pointsMap.values
                .map((point) => [point['0'] as int, point['1'] as int])
                .toList();
          }
        }

        if (polygonFromDrawing != null &&
            polygonFromDrawing!['loccam'] != null) {
          updatedData['loccam'] = polygonFromDrawing!['loccam'];
        } else if (oldInfo['loccam'] != null) {
          updatedData['loccam'] = oldInfo['loccam'];
        }

        if (newLocation != null) {
          updatedData['location'] = newLocation;
        } else if (oldInfo.containsKey('location')) {
          updatedData['location'] = oldInfo['location'];
        }

        if (nameChanged) {
          final exists = (await newRef.get()).exists;
          if (exists) {
            setState(() => isSaving = false); // ✅
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('الاسم الجديد موجود بالفعل.')),
            );
            return;
          }

          final oldSnapshot = await oldRef.get();
          if (oldSnapshot.exists) {
            await newRef.set(
                oldSnapshot.value); // ✅ نسخ كامل (info + month + أي شيء آخر)
            await oldRef.remove();
            await Future.delayed(const Duration(milliseconds: 100));
            // ✅ بعد النسخ فقط احذف القديم
          }
        }

        await newRef.child('info').update(updatedData);
        print('✅ تم تحديث البيانات في Firebase');

        await Future.delayed(Duration(seconds: 1)); // ⭐ أضف دي هنا

        setState(() => isSaving = false); // ✅ إخفاء التحميل

        print(
            "✅ Returning from EditProfileScreen with newName: $newEmployeeName");

        Navigator.pop(context, {
          'newName': newEmployeeName,
          'newInfo': updatedData,
        });
      } catch (e) {
        setState(() => isSaving = false); // ✅
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('حدث خطأ أثناء التحديث: $e')),
        );
        print('❌ Error updating data: $e');
      }
    }
  }

  Widget _buildInputCard(
    String label,
    IconData icon,
    TextEditingController controller, {
    TextInputType inputType = TextInputType.text,
    String? Function(String?)? validator,
  }) {
    return Card(
      color: Colors.white,
      elevation: 3,
      shadowColor: Colors.indigo.withOpacity(0.2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: TextFormField(
          controller: controller,
          keyboardType: inputType,
          validator: validator,
          decoration: InputDecoration(
            icon: Icon(icon, color: Colors.indigo),
            labelText: '$label (editable)',
            floatingLabelStyle: const TextStyle(color: Colors.indigo),
            border: InputBorder.none,
            suffixIcon: const Icon(Icons.edit, size: 16, color: Colors.grey),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text('Edit Employee'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Tooltip(
                  message: "Tap to change employee picture",
                  child: GestureDetector(
                    onTap: pickImage,
                    child: CircleAvatar(
                      radius: 60,
                      backgroundColor: Colors.grey.shade300,
                      backgroundImage: newImageFile != null
                          ? FileImage(newImageFile!)
                          : (photoUrl != null && photoUrl!.isNotEmpty)
                              ? NetworkImage(photoUrl!) as ImageProvider
                              : null,
                      child: (newImageFile == null &&
                              (photoUrl == null || photoUrl!.isEmpty))
                          ? const Icon(Icons.add_a_photo,
                              size: 30, color: Colors.grey)
                          : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _buildInputCard(
                "Name",
                Icons.person,
                nameController,
                validator: (v) {
                  final trimmed = v?.trim() ?? '';
                  return trimmed.isEmpty ? 'Enter name' : null;
                },
              ),
              _buildInputCard(
                "Phone",
                Icons.phone,
                phoneController,
                inputType: TextInputType.phone,
                validator: (v) {
                  final trimmed = v?.trim() ?? '';
                  return trimmed.isEmpty ? 'Enter phone' : null;
                },
              ),
              _buildInputCard(
                "Address",
                Icons.home,
                addressController,
                validator: (v) {
                  final trimmed = v?.trim() ?? '';
                  return trimmed.isEmpty ? 'Enter address' : null;
                },
              ),
              _buildInputCard(
                "Salary",
                Icons.monetization_on,
                salaryController,
                inputType: TextInputType.number,
                validator: (v) {
                  final trimmed = v?.trim() ?? '';
                  if (trimmed.isEmpty) return 'Enter salary';
                  final value = int.tryParse(trimmed);
                  if (value == null) return 'Enter a valid number';
                  if (value <= 0) return 'Salary must be greater than 0';
                  return null;
                },
              ),
              _buildInputCard(
                "Working Hours",
                Icons.access_time,
                hoursController,
                inputType: TextInputType.number,
                validator: (v) {
                  final trimmed = v?.trim() ?? '';
                  if (trimmed.isEmpty) return 'Enter working hours';
                  final value = int.tryParse(trimmed);
                  if (value == null) return 'Enter a valid number';
                  if (value <= 0) return 'Hours must be greater than 0';
                  return null;
                },
              ),
              _buildInputCard("Position", Icons.work, positionController),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: Icon(
                  locationSelected ? Icons.check_circle : Icons.map,
                  color: Colors.white,
                ),
                label: Text(
                  locationSelected
                      ? "Workspace Selected"
                      : "Edit Workspace Location",
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      locationSelected ? Colors.teal : Colors.indigo,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: isSaving
                    ? null
                    : () async {
                        final selectedPolygon = await Navigator.pushNamed(
                          context,
                          ChooseLocationToEditScreen.screenRoute,
                          arguments: {
                            'employeeName': nameController.text.trim(),
                            'userName': username,
                          },
                        );
                        if (selectedPolygon != null && mounted) {
                          setState(() {
                            polygonFromDrawing =
                                selectedPolygon as Map<String, dynamic>;
                            locationSelected = true;
                          });
                        }
                      },
              ),
              const SizedBox(height: 20),
              Stack(
                alignment: Alignment.center,
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.save_alt),
                    label: const Text("Save Changes"),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: isSaving ? null : updateData,
                  ),
                  if (isSaving)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

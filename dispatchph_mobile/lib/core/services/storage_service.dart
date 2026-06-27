import 'dart:io';
import 'dart:ui' as ui;
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import 'supabase_service.dart';

class StorageService {
  static const _uuid = Uuid();
  static const _productsBucket = 'products';
  static const _evidenceBucket = 'disputes';
  static const _deliveryBucket = 'delivery';
  static const _chatMediaBucket = 'chat_media';
  static const maxFileSize = 2 * 1024 * 1024; // 2MB
  static const maxDimension = 1200;

  /// Returns file size in human-readable format
  static String getFileSize(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return '0 KB';
    final bytes = file.lengthSync();
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Returns true if file is under the size limit
  static bool isUnderSizeLimit(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return true;
    return file.lengthSync() <= maxFileSize;
  }

  /// Compress image to fit within size and dimension limits
  static Future<XFile?> compressImage(XFile xfile) async {
    try {
      final file = File(xfile.path);
      if (!file.existsSync()) return xfile;
      if (file.lengthSync() <= maxFileSize) return xfile;

      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes,
          targetWidth: maxDimension, targetHeight: maxDimension);
      final frame = await codec.getNextFrame();
      final resized = await frame.image.toByteData(format: ui.ImageByteFormat.png);

      if (resized == null) return xfile;

      final tempDir = Directory.systemTemp;
      final tempPath = '${tempDir.path}/${_uuid.v4()}.jpg';
      await File(tempPath).writeAsBytes(resized.buffer.asUint8List());
      return XFile(tempPath);
    } catch (e) {
      print('[StorageService] compressImage error: $e');
      return xfile;
    }
  }

  /// Compress all images in a list
  static Future<List<XFile>> compressImages(List<XFile> files) async {
    final results = <XFile>[];
    for (final f in files) {
      final compressed = await compressImage(f);
      results.add(compressed ?? f);
    }
    return results;
  }

  static Future<String?> uploadProductImage(String filePath, String vendorId) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final ext = filePath.split('.').last;
      final fileName = '${_uuid.v4()}.$ext';
      final path = '$vendorId/$fileName';

      await SupabaseService.client.storage.from(_productsBucket).upload(
            path,
            file,
          );

      final url = SupabaseService.client.storage.from(_productsBucket).getPublicUrl(path);
      print('[StorageService] Uploaded product image: $url');
      return url;
    } catch (e) {
      print('[StorageService] Upload product image error: $e');
      return null;
    }
  }

  static Future<List<String>> uploadProductImages(
      List<String> filePaths, String vendorId) async {
    final urls = <String>[];
    for (final path in filePaths) {
      final url = await uploadProductImage(path, vendorId);
      if (url != null) urls.add(url);
    }
    return urls;
  }

  static Future<void> deleteImage(String url) async {
    try {
      final uri = Uri.parse(url);
      final pathSegments = uri.pathSegments;
      final bucketIndex = pathSegments.indexOf(_productsBucket);
      if (bucketIndex >= 0 && bucketIndex < pathSegments.length - 1) {
        final filePath = pathSegments.sublist(bucketIndex + 1).join('/');
        await SupabaseService.client.storage.from(_productsBucket).remove([filePath]);
      }
    } catch (e) {
      print('[StorageService] Delete error: $e');
    }
  }

  /// Upload dispute evidence photo (buyer or vendor)
  static Future<String?> uploadDisputeEvidence({
    required String disputeId,
    required String filePath,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final ext = filePath.split('.').last;
      final fileName = '${_uuid.v4()}.$ext';
      final path = '$disputeId/$fileName';

      await SupabaseService.client.storage.from(_evidenceBucket).upload(
            path,
            file,
          );

      final url = SupabaseService.client.storage.from(_evidenceBucket).getPublicUrl(path);
      print('[StorageService] Uploaded dispute evidence: $url');
      return url;
    } catch (e) {
      print('[StorageService] Upload dispute evidence error: $e');
      return null;
    }
  }

  /// Upload shipping proof photo (vendor before shipping)
  static Future<String?> uploadShippingProof({
    required String orderId,
    required String filePath,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final ext = filePath.split('.').last;
      final fileName = 'shipping_${_uuid.v4()}.$ext';
      final path = '$orderId/$fileName';

      await SupabaseService.client.storage.from(_deliveryBucket).upload(
            path,
            file,
          );

      final url = SupabaseService.client.storage.from(_deliveryBucket).getPublicUrl(path);
      print('[StorageService] Uploaded shipping proof: $url');
      return url;
    } catch (e) {
      print('[StorageService] Upload shipping proof error: $e');
      return null;
    }
  }

  /// Upload delivery confirmation photo (buyer confirms receipt)
  static Future<String?> uploadDeliveryConfirmation({
    required String orderId,
    required String filePath,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final ext = filePath.split('.').last;
      final fileName = 'delivery_${_uuid.v4()}.$ext';
      final path = '$orderId/$fileName';

      await SupabaseService.client.storage.from(_deliveryBucket).upload(
            path,
            file,
          );

      final url = SupabaseService.client.storage.from(_deliveryBucket).getPublicUrl(path);
      print('[StorageService] Uploaded delivery confirmation: $url');
      return url;
    } catch (e) {
      print('[StorageService] Upload delivery confirmation error: $e');
      return null;
    }
  }

  /// Upload chat image or video
  static Future<String?> uploadChatMedia({
    required String chatId,
    required String filePath,
    String type = 'image',
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final ext = filePath.split('.').last;
      final prefix = type == 'video' ? 'vid' : 'img';
      final fileName = '${prefix}_${_uuid.v4()}.$ext';
      final path = '$chatId/$fileName';

      await SupabaseService.client.storage.from(_chatMediaBucket).upload(
            path,
            file,
          );

      final url = SupabaseService.client.storage.from(_chatMediaBucket).getPublicUrl(path);
      print('[StorageService] Uploaded chat $type: $url');
      return url;
    } catch (e) {
      print('[StorageService] Upload chat media error: $e');
      return null;
    }
  }

  /// Create storage buckets if they don't exist
  static Future<void> initializeBuckets() async {
    try {
      final buckets = await SupabaseService.client.storage.listBuckets();
      final existingNames = buckets.map((b) => b.name).toSet();

      if (!existingNames.contains(_productsBucket)) {
        await SupabaseService.client.storage.createBucket(_productsBucket);
        print('[StorageService] Created products bucket');
      }

      if (!existingNames.contains(_evidenceBucket)) {
        await SupabaseService.client.storage.createBucket(_evidenceBucket);
        print('[StorageService] Created disputes bucket');
      }

      if (!existingNames.contains(_deliveryBucket)) {
        await SupabaseService.client.storage.createBucket(_deliveryBucket);
        print('[StorageService] Created delivery bucket');
      }

      if (!existingNames.contains(_chatMediaBucket)) {
        await SupabaseService.client.storage.createBucket(_chatMediaBucket);
        print('[StorageService] Created chat_media bucket');
      }
    } catch (e) {
      print('[StorageService] Initialize buckets error: $e');
    }
  }
}

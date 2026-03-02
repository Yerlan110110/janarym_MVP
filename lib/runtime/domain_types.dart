class ShoppingItemState {
  const ShoppingItemState({
    required this.name,
    required this.targetQty,
    required this.pickedQty,
    required this.status,
    this.shelfHint,
  });

  final String name;
  final int targetQty;
  final int pickedQty;
  final String status;
  final String? shelfHint;
}

class StoreLayoutNode {
  const StoreLayoutNode({
    required this.storeId,
    required this.zoneType,
    required this.anchorObject,
    required this.x,
    required this.y,
    required this.confidence,
  });

  final int storeId;
  final String zoneType;
  final String anchorObject;
  final double x;
  final double y;
  final double confidence;
}

class CookingStepGuidance {
  const CookingStepGuidance({
    required this.stepId,
    required this.instruction,
    required this.handOffsetCm,
    required this.safetyNotes,
  });

  final String stepId;
  final String instruction;
  final double handOffsetCm;
  final String safetyNotes;
}

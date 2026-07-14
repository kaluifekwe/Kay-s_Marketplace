// Shared formatting helpers for the admin console.

export const naira = (v: number | string | null | undefined): string => {
  const n = Number(v ?? 0);
  return (
    "₦" +
    n.toLocaleString("en-NG", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    })
  );
};

// Colour map for order / dispute statuses so tables read at a glance.
export const statusColor = (status?: string): string => {
  switch ((status ?? "").toLowerCase()) {
    case "paid":
    case "confirmed":
    case "delivered":
    case "resolved":
      return "green";
    case "shipped":
    case "processing":
    case "awaiting_vendor_response":
      return "blue";
    case "cancelled":
    case "refunded":
    case "failed":
      return "red";
    case "pending":
      return "orange";
    default:
      return "default";
  }
};

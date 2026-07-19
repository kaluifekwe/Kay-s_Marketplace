import { useState } from "react";
import { Show } from "@refinedev/antd";
import { useShow } from "@refinedev/core";
import {
  Typography,
  Tag,
  Descriptions,
  Table,
  Card,
  Button,
  Space,
  Popconfirm,
  Input,
  Alert,
  App,
} from "antd";
import { DollarOutlined, RollbackOutlined } from "@ant-design/icons";
import { naira, statusColor } from "../../format";
import { supabaseClient } from "../../supabaseClient";
import { fnError } from "../../fnError";

const { Title, Paragraph } = Typography;

// process-refund accepts these order statuses when there is NO dispute attached.
// (confirmed / auto_released are refundable only through the dispute flow.)
const REFUNDABLE_STATUSES = ["paid", "shipped", "refund_requested", "delivery_failed"];
// release-escrow only releases a buyer-confirmed (or auto-released) order.
const RELEASABLE_STATUSES = ["confirmed", "auto_released"];

const ORDER_SHOW_SELECT =
  "*, buyer:users!orders_buyer_id_fkey(name,email,phone), " +
  "vendor:users!orders_vendor_id_fkey(name), " +
  "store:stores!orders_store_id_fkey(name)";

// Line items are stored as a JSON string in orders.items — parse defensively.
interface LineItem {
  name?: string;
  title?: string;
  product_name?: string;
  quantity?: number;
  qty?: number;
  price?: number;
  unit_price?: number;
}
function parseItems(raw: unknown): LineItem[] {
  if (typeof raw !== "string") return [];
  try {
    const v = JSON.parse(raw);
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

export const OrderShow = () => {
  const { message } = App.useApp();
  const { queryResult } = useShow({ meta: { select: ORDER_SHOW_SELECT } });
  const record = queryResult?.data?.data as Record<string, any> | undefined;
  const items = parseItems(record?.items);

  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState<null | "refund" | "release" | "held">(null);

  const status = record?.status as string | undefined;
  const canRefund = !!status && REFUNDABLE_STATUSES.includes(status);
  const canRelease =
    !!status && RELEASABLE_STATUSES.includes(status) && record?.payment_released !== true;
  // Vendor-arranged delivery, buyer never confirmed: auto-release deliberately
  // stopped rather than paying on a timer. It waits here for a person.
  const isHeld = record?.payout_held === true && record?.payment_released !== true;

  const run = async (
    action: "refund" | "release" | "held",
    fn: string,
    body: Record<string, unknown>,
    okMsg: string,
  ) => {
    setBusy(action);
    try {
      const { data, error } = await supabaseClient.functions.invoke(fn, { body });
      if (error) throw error;
      if ((data as any)?.error) throw new Error((data as any).message || (data as any).error);
      message.success((data as any)?.message || okMsg);
      setReason("");
      queryResult?.refetch();
    } catch (e: any) {
      message.error(await fnError(e, "Action failed."));
    } finally {
      setBusy(null);
    }
  };

  return (
    <Show isLoading={queryResult?.isLoading} title="Order">
      <Descriptions bordered column={1} size="middle">
        <Descriptions.Item label="Order ID">{record?.id ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Status">
          <Tag color={statusColor(record?.status)}>{record?.status ?? "—"}</Tag>
        </Descriptions.Item>
        <Descriptions.Item label="Buyer">
          {record?.buyer?.name ?? "—"}
          {record?.buyer?.phone ? ` · ${record.buyer.phone}` : ""}
          {record?.buyer?.email ? ` · ${record.buyer.email}` : ""}
        </Descriptions.Item>
        <Descriptions.Item label="Store / Vendor">
          {record?.store?.name ?? "—"}
          {record?.vendor?.name ? ` (${record.vendor.name})` : ""}
        </Descriptions.Item>
        <Descriptions.Item label="Items subtotal">{naira(record?.total)}</Descriptions.Item>
        <Descriptions.Item label="Delivery fee">
          {naira(record?.delivery_fee)}
          {record?.selected_courier_name ? ` · ${record.selected_courier_name}` : ""}
        </Descriptions.Item>
        <Descriptions.Item label="Total (with delivery)">
          {naira(record?.total_with_delivery ?? record?.total)}
        </Descriptions.Item>
        <Descriptions.Item label="Escrow">
          {record?.payment_released ? (
            <Tag color="green">Released to vendor</Tag>
          ) : (
            <Tag color="blue">Held</Tag>
          )}
          {record?.payout_status ? ` · payout: ${record.payout_status}` : ""}
        </Descriptions.Item>
        <Descriptions.Item label="Dispute">
          {record?.has_dispute ? <Tag color="red">Yes</Tag> : "No"}
        </Descriptions.Item>
        <Descriptions.Item label="Delivery method">
          {record?.delivery_method ?? record?.delivery_type ?? "—"}
        </Descriptions.Item>
        <Descriptions.Item label="Placed">{record?.created_at ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Paid / Delivered / Confirmed">
          {(record?.paid_at ?? "—") +
            "  /  " +
            (record?.delivered_at ?? "—") +
            "  /  " +
            (record?.confirmed_at ?? "—")}
        </Descriptions.Item>
      </Descriptions>

      <Title level={5} style={{ marginTop: 24 }}>
        Line items
      </Title>
      <Table
        dataSource={items.map((it, i) => ({ key: i, ...it }))}
        pagination={false}
        size="small"
        locale={{ emptyText: "No line items recorded" }}
      >
        <Table.Column
          title="Item"
          render={(_, it: LineItem) => it.name ?? it.title ?? it.product_name ?? "Item"}
        />
        <Table.Column
          title="Qty"
          render={(_, it: LineItem) => it.quantity ?? it.qty ?? "—"}
        />
        <Table.Column
          title="Price"
          render={(_, it: LineItem) =>
            it.price != null || it.unit_price != null
              ? naira(it.price ?? it.unit_price)
              : "—"
          }
        />
      </Table>

      <Card style={{ marginTop: 24, borderTop: "3px solid #1b8a3a" }} title="Admin actions">
        {record?.has_dispute && (
          <Alert
            type="warning"
            showIcon
            style={{ marginBottom: 16 }}
            message="This order has an active dispute"
            description="Escrow release is blocked until it's resolved. Use the Disputes page to approve or deny the refund."
          />
        )}

        {isHeld && (
          <Alert
            type="info"
            showIcon
            style={{ marginBottom: 16 }}
            message="Payout held — your decision is needed"
            description={
              <>
                This was a <b>vendor-arranged delivery</b> and the buyer never confirmed receipt. No
                courier confirmed it independently either, so nothing was released on the timer — the
                vendor is unpaid and the money is still held. Check the vendor's shipping photo and
                the chat before deciding. <b>Releasing pays the vendor on their own word</b>, so your
                reason is recorded against your name in the audit log.
                {record?.payout_held_at ? ` Held since ${new Date(record.payout_held_at).toLocaleString()}.` : ""}
              </>
            }
          />
        )}

        {(canRefund || isHeld) && (
          <>
            <Paragraph type="secondary" style={{ marginTop: 0 }}>
              <b>Refund order</b> returns the buyer's money to their wallet (credit-funded orders
              refund to credit), claws back the vendor if already paid, and marks the order refunded.
            </Paragraph>
            <Input.TextArea
              rows={2}
              placeholder="Reason for the refund (optional, stored on the transaction)"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              style={{ marginBottom: 16 }}
            />
          </>
        )}

        <Space wrap>
          {isHeld && (
            <Popconfirm
              title="Pay the vendor for this order?"
              description="The buyer never confirmed receipt. Pays the vendor now; this cannot be undone."
              okText="Pay vendor"
              onConfirm={() =>
                run(
                  "held",
                  "admin-release-held-payout",
                  { order_id: record?.id, decision: "release", reason },
                  "Payout released to the vendor.",
                )
              }
            >
              <Button
                type="primary"
                icon={<DollarOutlined />}
                loading={busy === "held"}
                disabled={busy !== null || reason.trim().length < 5}
              >
                Release held payout
              </Button>
            </Popconfirm>
          )}
          {canRelease && (
            <Popconfirm
              title="Release escrow to the vendor?"
              description="Pays the vendor now. This cannot be undone."
              okText="Release"
              onConfirm={() =>
                run("release", "release-escrow", { order_id: record?.id }, "Escrow released to vendor.")
              }
            >
              <Button
                type="primary"
                icon={<DollarOutlined />}
                loading={busy === "release"}
                disabled={busy !== null}
              >
                Release escrow to vendor
              </Button>
            </Popconfirm>
          )}
          {canRefund && (
            <Popconfirm
              title="Refund this order?"
              description="The buyer is refunded immediately. This cannot be undone."
              okText="Refund"
              okButtonProps={{ danger: true }}
              onConfirm={() =>
                run(
                  "refund",
                  "process-refund",
                  {
                    order_id: record?.id,
                    reason: reason.trim() || "Refunded by admin",
                    refund_method: "wallet",
                  },
                  "Order refunded to the buyer's wallet.",
                )
              }
            >
              <Button
                danger
                icon={<RollbackOutlined />}
                loading={busy === "refund"}
                disabled={busy !== null}
              >
                Refund order
              </Button>
            </Popconfirm>
          )}
        </Space>

        {!canRefund && !canRelease && (
          <Alert
            type="info"
            showIcon
            message="No admin actions available"
            description={
              record?.payment_released
                ? `Escrow is already released to the vendor and this order is "${status}".`
                : `Nothing to do for an order in "${status}". Refunds apply to ${REFUNDABLE_STATUSES.join(", ")}; escrow release applies to ${RELEASABLE_STATUSES.join(", ")}. A delivered-and-confirmed order is refunded through the dispute flow.`
            }
          />
        )}
      </Card>
    </Show>
  );
};

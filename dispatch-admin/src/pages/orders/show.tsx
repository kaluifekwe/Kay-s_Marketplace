import { Show } from "@refinedev/antd";
import { useShow } from "@refinedev/core";
import { Typography, Tag, Descriptions, Table } from "antd";
import { naira, statusColor } from "../../format";

const { Title } = Typography;

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
  const { queryResult } = useShow({ meta: { select: ORDER_SHOW_SELECT } });
  const record = queryResult?.data?.data;
  const items = parseItems(record?.items);

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
    </Show>
  );
};

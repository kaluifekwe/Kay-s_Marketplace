import { List, useTable, ShowButton, DateField } from "@refinedev/antd";
import { Table, Space, Tag } from "antd";
import { naira, statusColor } from "../../format";

// Embed buyer + store names so the list reads in plain language, not UUIDs.
const ORDER_LIST_SELECT =
  "*, buyer:users!orders_buyer_id_fkey(name), store:stores!orders_store_id_fkey(name)";

export const OrderList = () => {
  const { tableProps } = useTable({
    syncWithLocation: true,
    sorters: { initial: [{ field: "created_at", order: "desc" }] },
    meta: { select: ORDER_LIST_SELECT },
  });

  return (
    <List>
      <Table {...tableProps} rowKey="id">
        <Table.Column
          dataIndex="id"
          title="Order"
          render={(v: string) => (
            <span style={{ fontFamily: "monospace" }}>{v?.slice(0, 8)}</span>
          )}
        />
        <Table.Column
          title="Buyer"
          render={(_, r: { buyer?: { name?: string } }) => r.buyer?.name ?? "—"}
        />
        <Table.Column
          title="Store"
          render={(_, r: { store?: { name?: string } }) => r.store?.name ?? "—"}
        />
        <Table.Column
          dataIndex="status"
          title="Status"
          render={(v: string) => <Tag color={statusColor(v)}>{v}</Tag>}
        />
        <Table.Column
          dataIndex="total_with_delivery"
          title="Total"
          render={(v, r: { total?: number }) => naira(v ?? r?.total)}
        />
        <Table.Column
          dataIndex="payment_released"
          title="Escrow"
          render={(v: boolean) =>
            v ? <Tag color="green">Released</Tag> : <Tag color="blue">Held</Tag>
          }
        />
        <Table.Column
          dataIndex="has_dispute"
          title="Dispute"
          render={(v: boolean) => (v ? <Tag color="red">Yes</Tag> : "—")}
        />
        <Table.Column
          dataIndex="created_at"
          title="Placed"
          render={(v) => (v ? <DateField value={v} format="YYYY-MM-DD HH:mm" /> : "—")}
        />
        <Table.Column
          title="Actions"
          dataIndex="actions"
          render={(_, record: { id: string }) => (
            <Space>
              <ShowButton hideText size="small" recordItemId={record.id} />
            </Space>
          )}
        />
      </Table>
    </List>
  );
};

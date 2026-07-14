import { List, useTable, ShowButton, DateField } from "@refinedev/antd";
import { Table, Space, Tag } from "antd";
import { naira, statusColor } from "../../format";

export const OrderList = () => {
  const { tableProps } = useTable({
    syncWithLocation: true,
    sorters: { initial: [{ field: "created_at", order: "desc" }] },
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
          dataIndex="status"
          title="Status"
          render={(v: string) => <Tag color={statusColor(v)}>{v}</Tag>}
        />
        <Table.Column
          dataIndex="total_with_delivery"
          title="Total"
          render={(v, record: { total?: number }) =>
            naira(v ?? record?.total)
          }
        />
        <Table.Column
          dataIndex="payment_released"
          title="Escrow"
          render={(v: boolean) =>
            v ? (
              <Tag color="green">Released</Tag>
            ) : (
              <Tag color="blue">Held</Tag>
            )
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

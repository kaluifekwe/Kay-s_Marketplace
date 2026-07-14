import { List, useTable, ShowButton, DateField } from "@refinedev/antd";
import { Table, Space, Tag } from "antd";
import { statusColor } from "../../format";

export const DisputeList = () => {
  const { tableProps } = useTable({
    syncWithLocation: true,
    sorters: { initial: [{ field: "created_at", order: "desc" }] },
  });

  return (
    <List>
      <Table {...tableProps} rowKey="id">
        <Table.Column
          dataIndex="id"
          title="Dispute"
          render={(v: string) => (
            <span style={{ fontFamily: "monospace" }}>{v?.slice(0, 8)}</span>
          )}
        />
        <Table.Column
          dataIndex="order_id"
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
          dataIndex="reason"
          title="Reason"
          render={(v: string) => (v ? v : "—")}
        />
        <Table.Column
          dataIndex="created_at"
          title="Opened"
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

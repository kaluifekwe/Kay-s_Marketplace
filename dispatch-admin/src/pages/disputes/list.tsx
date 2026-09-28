import { List, useTable, ShowButton, DateField } from "@refinedev/antd";
import { Table, Space, Tag } from "antd";
import { statusColor } from "../../format";

const DISPUTE_LIST_SELECT =
  "*, buyer:users!disputes_buyer_id_fkey(name), vendor:users!disputes_vendor_id_fkey(name)";

export const DisputeList = () => {
  const { tableProps } = useTable({
    syncWithLocation: true,
    sorters: { initial: [{ field: "created_at", order: "desc" }] },
    meta: { select: DISPUTE_LIST_SELECT },
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
          title="Buyer"
          render={(_, r: { buyer?: { name?: string } }) => r.buyer?.name ?? "—"}
        />
        <Table.Column
          title="Vendor"
          render={(_, r: { vendor?: { name?: string } }) => r.vendor?.name ?? "—"}
        />
        <Table.Column
          dataIndex="status"
          title="Status"
          render={(v: string) => <Tag color={statusColor(v)}>{v}</Tag>}
        />
        <Table.Column
          dataIndex="issue_type"
          title="Issue"
          render={(v: string) => v ?? "—"}
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

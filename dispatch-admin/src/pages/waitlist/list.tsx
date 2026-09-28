import { List, useTable, DateField } from "@refinedev/antd";
import { Table, Tag, Radio, Space, Alert } from "antd";
import type { CrudFilters } from "@refinedev/core";

type Row = {
  id: string;
  email: string;
  role: "buyer" | "vendor";
  state: string | null;
  source: string;
  created_at: string;
};

export const WaitlistList = () => {
  const { tableProps, setFilters, filters, tableQueryResult } = useTable<Row>({
    syncWithLocation: true,
    sorters: { initial: [{ field: "created_at", order: "desc" }] },
  });

  const roleFilter = filters?.find((f) => "field" in f && f.field === "role") as any;
  const activeKey = roleFilter ? roleFilter.value : "all";

  const applyFilter = (key: string) => {
    const next: CrudFilters = key === "all" ? [] : [{ field: "role", operator: "eq", value: key }];
    setFilters(next, "replace");
  };

  const err = (tableQueryResult as any)?.error;
  if (err) {
    return (
      <Alert
        type="error"
        showIcon
        message="Could not load the waitlist"
        description={`${err?.message ?? err}. Have you run waitlist_signups.sql?`}
      />
    );
  }

  return (
    <List title="Waitlist" canCreate={false}>
      <Space style={{ marginBottom: 16 }}>
        <Radio.Group value={activeKey} onChange={(e) => applyFilter(e.target.value)} optionType="button" buttonStyle="solid">
          <Radio.Button value="all">All</Radio.Button>
          <Radio.Button value="buyer">Buyers</Radio.Button>
          <Radio.Button value="vendor">Vendors</Radio.Button>
        </Radio.Group>
      </Space>

      <Table {...tableProps} rowKey="id" size="middle">
        <Table.Column dataIndex="email" title="Email" />
        <Table.Column
          dataIndex="role"
          title="Role"
          width={100}
          render={(v: string) => <Tag color={v === "vendor" ? "purple" : "blue"}>{v}</Tag>}
        />
        <Table.Column dataIndex="state" title="State" render={(v) => v ?? "—"} />
        <Table.Column dataIndex="source" title="Source" render={(v) => v ?? "—"} />
        <Table.Column
          dataIndex="created_at"
          title="Joined"
          render={(v: string) => (v ? <DateField value={v} format="YYYY-MM-DD HH:mm" /> : "—")}
        />
      </Table>
    </List>
  );
};

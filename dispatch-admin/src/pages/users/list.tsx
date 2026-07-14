import { List, useTable, ShowButton, DateField } from "@refinedev/antd";
import { Table, Space, Tag, Input } from "antd";
import { useState } from "react";

const roleColor: Record<string, string> = {
  admin: "purple",
  vendor: "geekblue",
  buyer: "green",
  rider: "orange",
};

export const UserList = () => {
  const { tableProps, setFilters } = useTable({
    syncWithLocation: true,
    sorters: { initial: [{ field: "created_at", order: "desc" }] },
  });
  const [q, setQ] = useState("");

  return (
    <List>
      <Input.Search
        placeholder="Search name or email"
        allowClear
        style={{ maxWidth: 320, marginBottom: 16 }}
        value={q}
        onChange={(e) => setQ(e.target.value)}
        onSearch={(value) => {
          setFilters(
            value
              ? [
                  {
                    operator: "or",
                    value: [
                      { field: "name", operator: "contains", value },
                      { field: "email", operator: "contains", value },
                    ],
                  },
                ]
              : [],
            "replace",
          );
        }}
      />
      <Table {...tableProps} rowKey="id">
        <Table.Column dataIndex="name" title="Name" />
        <Table.Column dataIndex="email" title="Email" />
        <Table.Column
          dataIndex="role"
          title="Role"
          render={(v: string) => <Tag color={roleColor[v] ?? "default"}>{v}</Tag>}
        />
        <Table.Column dataIndex="state" title="State" />
        <Table.Column
          dataIndex="created_at"
          title="Joined"
          render={(v) => (v ? <DateField value={v} format="YYYY-MM-DD" /> : "—")}
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

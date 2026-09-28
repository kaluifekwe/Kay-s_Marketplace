import { List, useTable } from "@refinedev/antd";
import { Table, Tag, Radio, Space, Typography, Alert } from "antd";
import { useNavigate } from "react-router-dom";
import type { CrudFilters } from "@refinedev/core";

const { Text } = Typography;

const STATUS_COLOR: Record<string, string> = {
  DISCOVERED: "default",
  RESEARCHING: "default",
  DRAFTED: "blue",
  REVIEW: "gold",
  APPROVED: "cyan",
  PUBLISHED: "green",
  UPDATED: "green",
  REJECTED: "red",
};

export const ContentList = () => {
  const navigate = useNavigate();

  const { tableProps, setFilters, filters, tableQueryResult } = useTable({
    syncWithLocation: true,
    sorters: { initial: [{ field: "updated_at", order: "desc" }] },
    filters: { initial: [{ field: "content_status", operator: "ne", value: "PUBLISHED" }] },
  });

  const statusFilter = filters?.find((f) => "field" in f && f.field === "content_status") as any;
  const activeKey = statusFilter ? (statusFilter.operator === "ne" ? "needs_work" : statusFilter.value) : "all";

  const applyFilter = (key: string) => {
    const next: CrudFilters =
      key === "all"
        ? []
        : key === "needs_work"
          ? [{ field: "content_status", operator: "ne", value: "PUBLISHED" }]
          : [{ field: "content_status", operator: "eq", value: key }];
    setFilters(next, "replace");
  };

  const err = (tableQueryResult as any)?.error;
  if (err) {
    return (
      <Alert
        type="error"
        showIcon
        message="Could not load the content queue"
        description={`${err?.message ?? err}. Have you run blog_content_engine.sql?`}
      />
    );
  }

  return (
    <List title="Content queue" createButtonProps={{ children: "Add topic" }}>
      <Space style={{ marginBottom: 16 }}>
        <Radio.Group
          value={activeKey}
          onChange={(e) => applyFilter(e.target.value)}
          optionType="button"
          buttonStyle="solid"
        >
          <Radio.Button value="needs_work">Needs work</Radio.Button>
          <Radio.Button value="REVIEW">Review</Radio.Button>
          <Radio.Button value="PUBLISHED">Published</Radio.Button>
          <Radio.Button value="REJECTED">Rejected</Radio.Button>
          <Radio.Button value="all">All</Radio.Button>
        </Radio.Group>
      </Space>

      <Table
        {...tableProps}
        rowKey="id"
        size="middle"
        onRow={(record: any) => ({
          onClick: () => navigate(`/content/show/${record.id}`),
          style: { cursor: "pointer" },
        })}
      >
        <Table.Column dataIndex="topic" title="Topic" />
        <Table.Column
          dataIndex="audience"
          title="Audience"
          width={100}
          render={(v: string) => <Tag color={v === "vendor" ? "purple" : "blue"}>{v}</Tag>}
        />
        <Table.Column dataIndex="category" title="Category" render={(v) => v ?? "—"} />
        <Table.Column dataIndex="state" title="State" render={(v) => v ?? "—"} />
        <Table.Column
          dataIndex="content_status"
          title="Status"
          render={(v: string) => <Tag color={STATUS_COLOR[v] ?? "default"}>{v}</Tag>}
        />
        <Table.Column dataIndex="priority" title="Priority" width={90} align="right" />
        <Table.Column
          dataIndex="updated_at"
          title="Updated"
          render={(v: string) => (v ? <Text type="secondary">{new Date(v).toLocaleString()}</Text> : "—")}
        />
      </Table>
    </List>
  );
};

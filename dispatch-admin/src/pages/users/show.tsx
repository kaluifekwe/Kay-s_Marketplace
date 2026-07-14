import { Show } from "@refinedev/antd";
import { useShow } from "@refinedev/core";
import { Typography, Tag, Descriptions } from "antd";

const { Title } = Typography;

export const UserShow = () => {
  const { queryResult } = useShow();
  const record = queryResult?.data?.data;

  return (
    <Show isLoading={queryResult?.isLoading} title={record?.name ?? "User"}>
      <Descriptions bordered column={1} size="middle">
        <Descriptions.Item label="Name">{record?.name ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Email">{record?.email ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Phone">{record?.phone ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Role">
          <Tag>{record?.role ?? "—"}</Tag>
        </Descriptions.Item>
        <Descriptions.Item label="State">{record?.state ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="KYC (NIN/BVN)">
          {record?.nin ? "Verified" : "Not verified"}
        </Descriptions.Item>
        <Descriptions.Item label="Kays Credit">
          {record?.kays_credit ?? 0}
        </Descriptions.Item>
        <Descriptions.Item label="Payout blocked">
          {record?.payout_blocked ? (
            <Tag color="red">Yes</Tag>
          ) : (
            <Tag color="green">No</Tag>
          )}
        </Descriptions.Item>
        <Descriptions.Item label="User ID">{record?.id ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Store ID">
          {record?.store_id ?? "—"}
        </Descriptions.Item>
        <Descriptions.Item label="Joined">
          {record?.created_at ?? "—"}
        </Descriptions.Item>
      </Descriptions>
      <Title level={5} style={{ marginTop: 24, color: "#888" }}>
        Wallet, orders, disputes and admin actions land here in Phase 2.
      </Title>
    </Show>
  );
};

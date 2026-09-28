import { useEffect, useState } from "react";
import { Row, Col, Card, Statistic, Spin, Alert, Typography } from "antd";
import {
  ShoppingOutlined,
  WarningOutlined,
  WalletOutlined,
  BankOutlined,
  TeamOutlined,
} from "@ant-design/icons";
import { supabaseClient } from "../supabaseClient";
import { naira } from "../format";

const { Title } = Typography;

interface Stats {
  orders_total: number;
  orders_today: number;
  gmv: number;
  escrow_held: number;
  open_disputes: number;
  withdrawals_pending_count: number;
  withdrawals_pending_sum: number;
  wallet_liability: number;
  buyers: number;
  vendors: number;
}

export const Dashboard = () => {
  const [stats, setStats] = useState<Stats | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    supabaseClient.rpc("admin_dashboard_stats").then(({ data, error }) => {
      if (error) setError(error.message);
      else setStats(data as Stats);
    });
  }, []);

  if (error) {
    return (
      <Alert
        type="error"
        showIcon
        message="Could not load dashboard stats"
        description={`${error}. Have you run admin_read_policies_phase2.sql?`}
      />
    );
  }
  if (!stats) {
    return (
      <div style={{ textAlign: "center", padding: 80 }}>
        <Spin size="large" />
      </div>
    );
  }

  const card = (child: React.ReactNode, accent?: string) => (
    <Card style={accent ? { borderTop: `3px solid ${accent}` } : undefined}>
      {child}
    </Card>
  );

  return (
    <>
      <Title level={3} style={{ marginTop: 0 }}>
        Overview
      </Title>
      <Row gutter={[16, 16]}>
        <Col xs={24} sm={12} lg={6}>
          {card(
            <Statistic
              title="Orders"
              value={stats.orders_total}
              prefix={<ShoppingOutlined />}
              suffix={
                <span style={{ fontSize: 13, color: "#52c41a" }}>
                  +{stats.orders_today} today
                </span>
              }
            />,
          )}
        </Col>
        <Col xs={24} sm={12} lg={6}>
          {card(
            <Statistic title="GMV (paid)" value={naira(stats.gmv)} />,
            "#1b8a3a",
          )}
        </Col>
        <Col xs={24} sm={12} lg={6}>
          {card(
            <Statistic
              title="Escrow held"
              value={naira(stats.escrow_held)}
              prefix={<WalletOutlined />}
            />,
            "#1677ff",
          )}
        </Col>
        <Col xs={24} sm={12} lg={6}>
          {card(
            <Statistic
              title="Open disputes"
              value={stats.open_disputes}
              prefix={<WarningOutlined />}
              valueStyle={{ color: stats.open_disputes > 0 ? "#cf1322" : undefined }}
            />,
            stats.open_disputes > 0 ? "#cf1322" : undefined,
          )}
        </Col>

        <Col xs={24} sm={12} lg={6}>
          {card(
            <Statistic
              title="Pending withdrawals"
              value={stats.withdrawals_pending_count}
              prefix={<BankOutlined />}
              suffix={
                <span style={{ fontSize: 13, color: "#888" }}>
                  {naira(stats.withdrawals_pending_sum)}
                </span>
              }
            />,
          )}
        </Col>
        <Col xs={24} sm={12} lg={6}>
          {card(
            <Statistic
              title="Wallet liability"
              value={naira(stats.wallet_liability)}
              prefix={<WalletOutlined />}
            />,
          )}
        </Col>
        <Col xs={24} sm={12} lg={6}>
          {card(
            <Statistic
              title="Buyers"
              value={stats.buyers}
              prefix={<TeamOutlined />}
            />,
          )}
        </Col>
        <Col xs={24} sm={12} lg={6}>
          {card(
            <Statistic
              title="Vendors"
              value={stats.vendors}
              prefix={<TeamOutlined />}
            />,
          )}
        </Col>
      </Row>
    </>
  );
};

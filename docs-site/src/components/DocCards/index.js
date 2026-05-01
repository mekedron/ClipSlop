import clsx from 'clsx';
import Link from '@docusaurus/Link';
import styles from './styles.module.css';

export default function DocCards({children}) {
  return <div className={styles.grid}>{children}</div>;
}

export function DocCard({
  to,
  href,
  keyLabel,
  color = 'accent',
  title,
  cta,
  children,
}) {
  const target = to ?? href ?? '#';
  const isExternal = !!href && !to;
  const colorClass = styles[`color_${color}`] || styles.color_accent;
  return (
    <Link
      to={isExternal ? undefined : target}
      href={isExternal ? target : undefined}
      className={clsx(styles.card, colorClass)}>
      {keyLabel && <span className={styles.key}>{keyLabel}</span>}
      <div className={styles.title}>{title}</div>
      {children && <div className={styles.desc}>{children}</div>}
      {cta && <span className={styles.arrow}>{cta} →</span>}
    </Link>
  );
}

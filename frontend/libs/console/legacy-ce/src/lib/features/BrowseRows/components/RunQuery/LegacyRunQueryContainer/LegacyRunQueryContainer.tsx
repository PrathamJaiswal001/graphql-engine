import { useAppDispatch, useAppSelector } from '@/store';
import React from 'react';
import {
  downloadObjectAsCsvFile,
  downloadObjectAsJsonFile,
  getCurrTimeForFileName,
} from '@/components/Common/utils/jsUtils';
import { Table } from '@/features/hasura-metadata-types';
import { vMakeExportRequest } from '../../../../../components/Services/Data/TableBrowseRows/ViewActions';
import { setOffset } from '../../../../../components/Services/Data/TableBrowseRows/FilterActions';
import {
  adaptFormValuesToQuery,
  filterValidUserQuery,
  runFilterQuery,
  setUrlParams,
} from './LegacyRunQueryContainer.utils';
import { LegacyRunQuery } from './LegacyRunQuery';
import { FiltersAndSortFormValues, UserQuery } from '../types';
import { useLegacyTableColumns } from '../hooks/useLegacyTableColumns';
import { useTableName } from '../hooks/useTableName';
import { useDatabaseOperators } from '../hooks/useDatabaseOperators';
import { useTableSchema } from '../hooks/useTableSchema';

type LegacyRunQueryContainerProps = {
  onRunQuery: (userQuery: UserQuery) => void | null;
  dataSourceName: string;
  table: Table;
  initialFiltersAndSort: FiltersAndSortFormValues;
};

const replaceAllDotsWithUnderscore = (text: string) => text.replace(/\./g, '_');
const getFileName = (tableName: string) => {
  const replacedTableName = replaceAllDotsWithUnderscore(tableName);
  const currentTime = getCurrTimeForFileName();
  return `export_${replacedTableName}_${currentTime}`;
};

export const getFiltersAndSortFromUrlQueryParams =
  (): FiltersAndSortFormValues => {
    const params = new URLSearchParams(window.location.search);
    const filters = params.getAll('filter') ?? [];
    const sorts = params.getAll('sort') ?? [];

    return {
      filters: filters.map(filter => {
        const [column, operator, value] = filter.split(';');
        return {
          column,
          operator,
          value,
        };
      }),
      sorts: sorts.map(filter => {
        const [column, type] = filter.split(';');
        return {
          column,
          type: type as FiltersAndSortFormValues['sorts'][0]['type'],
        };
      }),
    };
  };
export const LegacyRunQueryContainer = ({
  onRunQuery,
  dataSourceName,
  table,
  initialFiltersAndSort,
}: LegacyRunQueryContainerProps) => {
  const dispatch = useAppDispatch();
  const curFilter = useAppSelector(state => state.tables.view.curFilter);
  const limit = curFilter.limit;

  const tableColumns = useLegacyTableColumns({ dataSourceName, table });
  const tableOperators = useDatabaseOperators({ dataSourceName });
  const tableSchema = useTableSchema(table);

  const onSubmit = (userQuery: UserQuery) => {
    if (!tableSchema) {
      console.error('tableSchema is not defined', tableSchema);
      return;
    }

    dispatch(setOffset(0));

    setUrlParams(userQuery.where.$and, userQuery.order_by);
    dispatch(
      runFilterQuery({
        tableSchema,
        whereAnd: userQuery.where.$and,
        orderBy: userQuery.order_by,
        limit,
        offset: 0,
      })
    );
  };

  const tableName = useTableName({ dataSourceName, table });
  const onExportData = (
    type: 'CSV' | 'JSON',
    formValues: FiltersAndSortFormValues
  ) => {
    const userQuery = filterValidUserQuery(
      adaptFormValuesToQuery(formValues, tableColumns)
    );

    const fileName = getFileName(tableName);
    dispatch({ type: 'ViewTable/V_SET_QUERY_OPTS', queryStuff: userQuery });
    dispatch(vMakeExportRequest()).then((rows: Record<string, unknown>[]) => {
      if (!rows || rows.length === 0) {
        return;
      }

      switch (type) {
        case 'JSON':
          downloadObjectAsJsonFile(fileName, rows);
          break;
        case 'CSV':
          downloadObjectAsCsvFile(fileName, rows);
          break;
        default:
      }
    });
  };

  const onSubmitHandler = (values: FiltersAndSortFormValues) => {
    const userQuery = filterValidUserQuery(
      adaptFormValuesToQuery(values, tableColumns)
    );
    if (onRunQuery) {
      onRunQuery(userQuery);
    }
    onSubmit(userQuery);
  };

  return (
    <LegacyRunQuery
      columns={tableColumns}
      operators={tableOperators}
      onExport={onExportData}
      initialFiltersAndSort={initialFiltersAndSort}
      uniqueTableName={`${tableSchema?.table_schema}.${tableSchema?.table_name}`}
      onSubmit={onSubmitHandler}
    />
  );
};

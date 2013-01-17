package Geo::CEP;
# ABSTRACT: Resolve Brazilian city data for a given CEP

=for test_synopsis

=head1 SYNOPSIS

    use common::sense;
    use utf8::all;

    use Data::Printer;
    use Geo::CEP;

    my $gc = Geo::CEP->new;
    p $gc->find("12420-010");

    # Saída:
    # \ {
    #     cep_final    12449999
    #     cep_initial  12400000
    #     city         "Pindamonhangaba",
    #     ddd          12,
    #     lat          -22.9166667,
    #     lon          -45.4666667,
    #     state        "SP",
    #     state_long   "São Paulo"
    # }

=head1 DESCRIPTION

Obtém os dados como: nome da cidade, do estado, número DDD e latitude/longitude (da cidade) para um número CEP (Código de Endereçamento Postal) brasileiro.

Diferentemente do L<WWW::Correios::CEP>, consulta os dados armazenados localmente.
Por um lado, isso faz L<Geo::CEP> ser extremamente rápido (5 mil consultas por segundo); por outro, somente as informações à nível de cidade são retornadas.

=cut

use strict;
use utf8;
use warnings qw(all);

use integer;

use Carp qw(carp confess croak);
use File::ShareDir qw(dist_file);
use IO::File;
use Memoize;
use Moo;
use MooX::Types::MooseLike::Base qw(:all);
use Scalar::Util qw(looks_like_number);
use Text::CSV;

# VERSION

has csv     => (is => 'ro', isa => InstanceOf['Text::CSV'], default => sub { Text::CSV->new }, lazy => 1);

=attr data, index

I<FileHandle> para os respectivos arquivos.

=cut

has data    => (is => 'rwp', isa => FileHandle);
has index   => (is => 'rwp', isa => FileHandle);

=attr length

Tamanho do índice.

=cut

has length  => (is => 'rwp', isa => Int, default => sub { 0 });

=attr states

Mapeamento de código de estado para o nome do estado (C<AC =E<gt> 'Acre'>).

=cut

my %states = (
    AC  => 'Acre',
    AL  => 'Alagoas',
    AM  => 'Amazonas',
    AP  => 'Amapá',
    BA  => 'Bahia',
    CE  => 'Ceará',
    DF  => 'Distrito Federal',
    ES  => 'Espírito Santo',
    GO  => 'Goiás',
    MA  => 'Maranhão',
    MG  => 'Minas Gerais',
    MS  => 'Mato Grosso do Sul',
    MT  => 'Mato Grosso',
    PA  => 'Pará',
    PB  => 'Paraíba',
    PE  => 'Pernambuco',
    PI  => 'Piauí',
    PR  => 'Paraná',
    RJ  => 'Rio de Janeiro',
    RN  => 'Rio Grande do Norte',
    RO  => 'Rondônia',
    RR  => 'Roraima',
    RS  => 'Rio Grande do Sul',
    SC  => 'Santa Catarina',
    SE  => 'Sergipe',
    SP  => 'São Paulo',
    TO  => 'Tocantins',
);

has states  => (
    is      => 'ro',
    isa     => HashRef[Str],
    default => sub { \%states }
);

# Tamanho do registro de índice.
my $idx_len = length(pack('N*', 1 .. 2));

=for Pod::Coverage
BUILD
DEMOLISH
=cut

sub BUILD {
    my ($self) = @_;

    $self->csv->column_names([qw(cep_initial cep_final state city ddd lat lon)]);

    my $data = IO::File->new(dist_file('Geo-CEP', 'cep.csv'), '<:encoding(latin1)');
    confess "Error opening CSV: $!" unless defined $data;
    $self->_set_data($data);

    my $index = IO::File->new(dist_file('Geo-CEP', 'cep.idx'), O_RDONLY);
    confess "Error opening index: $!" unless defined $index;
    $self->_set_index($index);

    my $size = $index->sysseek(0, SEEK_END)
        or confess "Can't tell(): $!";

    confess 'Inconsistent index size'
        if not $size or
        ($size % $idx_len);
    $self->_set_length($size / $idx_len);

    return;
}

=method get_idx($n)

Retorna o registro no arquivo CSV; uso interno.

=cut

memoize 'get_idx';
sub get_idx {
    my ($self, $n, $lazy) = @_;

    my $buf = '';
    $self->index->sysseek($n * $idx_len, SEEK_SET)
        or confess "Can't seek(): $!";

    $self->index->sysread($buf, $idx_len)
        or confess "Can't read(): $!";

    my ($cep, $offset) = unpack('N*', $buf);
    return defined $lazy
        ? sub { $self->fetch_row($offset) }
        : $cep;
}

=method bsearch($hi, $val)

Efetua a busca binária (implementação não-recursiva); uso interno.

=cut

memoize 'bsearch';
sub bsearch {
    my ($self, $hi, $val) = @_;
    my ($lo, $cep, $mid) = qw(0 0 0);

    return
        if ($self->get_idx($lo) > $val)
        or ($self->get_idx($hi) < $val);

    while ($lo <= $hi) {
        $mid = int(($lo + $hi) / 2);
        $cep = $self->get_idx($mid);
        if ($val < $cep) {
            $hi = $mid - 1;
        } elsif ($val > $cep) {
            $lo = $mid + 1;
        } else {
            last;
        }
    }

    --$mid if $cep > $val;
    return $self->get_idx($mid, 1);
}

=method fetch_row($offset)

Lê e formata o registro a partir do F<cep.csv>; uso interno.

=cut

memoize 'fetch_row';
sub fetch_row {
    my ($self, $offset) = @_;

    no integer;

    $self->data->seek($offset, SEEK_SET)
        or confess "Can't seek(): $!";

    my $row = $self->csv->getline_hr($self->data);
    return if 'HASH' ne ref $row;

    my %res = map {
        $_ =>
            looks_like_number($row->{$_})
                ? 0 + sprintf('%.7f', $row->{$_})
                : $row->{$_}
    } qw(state city ddd lat lon cep_initial cep_final);
    return unless defined $res{state};
    $res{state_long}= $states{$res{state}};

    return \%res;
}

=method find($cep)

Busca por C<$cep> (no formato I<12345678> ou I<"12345-678">) e retorna I<HashRef> com:

=for :list
* I<state>: sigla da Unidade Federativa (SP, RJ, MG);
* I<state_long>: nome da Unidade Federativa (São Paulo, Rio de Janeiro, Minas Gerais);
* I<city>: nome da cidade;
* I<ddd>: código DDD (pode estar vazio);
* I<lat>/I<lon>: coordenadas geográficas da cidade (podem estar vazias).

Retorna C<undef> quando não foi possível encontrar.

=cut

memoize 'find';
sub find {
    my ($self, $cep) = @_;
    $cep =~ s/\D//gx;
    my $offset = $self->bsearch($self->length - 1, $cep);
    if ('CODE' eq ref $offset) {
        return $offset->();
    } else {
        return;
    }
}

=method list()

Retorna I<HashRef> com os dados de todas as cidades.

=cut

sub list {
    my ($self) = @_;

    $self->index->sysseek(0, SEEK_SET)
        or confess "Can't seek(): $!";

    my %list;
    my $buf;
    while ($self->index->sysread($buf, $idx_len)) {
        my (undef, $offset) = unpack('N*', $buf);
        my $row = $self->fetch_row($offset);
        $list{$row->{city} . '/' . $row->{state}} = $row
            if defined $row;
    }
    $self->csv->eof
        or croak $self->csv->error_diag;

    return \%list;
}

=head1 SEE ALSO

=for :list
* L<cep2city>
* L<Business::BR::CEP>
* L<WWW::Correios::CEP>
* L<WWW::Correios::PrecoPrazo>
* L<WWW::Correios::SRO>

=head1 CONTRIBUTORS

=for :list
* L<Blabos de Blebe|https://metacpan.org/author/BLABOS>

=cut

1;
